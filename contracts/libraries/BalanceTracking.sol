// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { Constants } from "./Constants.sol";
import { IExchange } from "./Interfaces.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { MarketOverrides } from "./MarketOverrides.sol";
import { Math } from "./Math.sol";
import { OrderSide } from "./Enums.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { UUID } from "./UUID.sol";
import { Balance, ExecuteOrderBookTradeArguments, Market, Order, OrderBookTrade, Withdrawal } from "./Structs.sol";

library BalanceTracking {
  using MarketOverrides for Market;
  using SortedStringSet for string[];

  struct Storage {
    mapping(address => mapping(string => Balance)) balancesByWalletAssetPair;
    // Predecessor Exchange contract from which to lazily migrate balances
    IExchange migrationSource;
  }

  // Depositing //

  function updateForDeposit(
    Storage storage self,
    address wallet,
    string memory assetSymbol,
    uint64 quantityInPips
  ) internal returns (int64 newBalanceInPips) {
    Balance storage balance = loadBalanceStructAndMigrateIfNeeded(self, wallet, assetSymbol);
    balance.balanceInPips += int64(quantityInPips);

    return balance.balanceInPips;
  }

  // Liquidation //

  function updatePositionForDeleverage(
    Storage storage self,
    int64 baseQuantityInPips,
    address counterpartyWallet,
    address liquidatingWallet,
    Market memory market,
    int64 quoteQuantityInPips,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal {
    _updatePositionForDeleverageOrLiquidation(
      self,
      true,
      baseQuantityInPips,
      counterpartyWallet,
      liquidatingWallet,
      market,
      quoteQuantityInPips,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function updatePositionForLiquidation(
    Storage storage self,
    int64 positionSizeInPips,
    address counterpartyWallet,
    address liquidatingWallet,
    Market memory market,
    int64 quoteQuantityInPips,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal {
    _updatePositionForDeleverageOrLiquidation(
      self,
      false,
      -1 * positionSizeInPips,
      counterpartyWallet,
      liquidatingWallet,
      market,
      quoteQuantityInPips,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function updatePositionForDeactivatedMarketLiquidation(
    Storage storage self,
    string memory baseAssetSymbol,
    address liquidatingWallet,
    int64 quoteQuantityInPips,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet
  ) internal {
    Balance storage balance;

    // Wallet position decreases by specified base quantity
    balance = loadBalanceStructAndMigrateIfNeeded(self, liquidatingWallet, baseAssetSymbol);
    balance.balanceInPips = 0;
    balance.costBasisInPips = 0;

    _updateOpenPositionsForWallet(
      liquidatingWallet,
      baseAssetSymbol,
      balance.balanceInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Wallet receives or gives quote if long or short respectively
    balance = loadBalanceStructAndMigrateIfNeeded(self, liquidatingWallet, Constants.QUOTE_ASSET_SYMBOL);
    balance.balanceInPips += quoteQuantityInPips;
  }

  function updateQuoteForLiquidation(
    Storage storage self,
    address counterpartyWallet,
    address liquidatingWallet
  ) internal {
    Balance storage balance;

    // Liquidating wallet quote balance goes to zero
    balance = loadBalanceStructAndMigrateIfNeeded(self, liquidatingWallet, Constants.QUOTE_ASSET_SYMBOL);
    int64 quoteQuantityInPips = balance.balanceInPips;
    balance.balanceInPips = 0;
    // Counterparty wallet takes any remaining quote from liquidating wallet
    if (quoteQuantityInPips != 0) {
      balance = loadBalanceStructAndMigrateIfNeeded(self, counterpartyWallet, Constants.QUOTE_ASSET_SYMBOL);
      balance.balanceInPips += quoteQuantityInPips;
    }
  }

  // Wallet exits //

  function updateForExit(
    Storage storage self,
    address exitFundWallet,
    Market memory market,
    uint64 indexPriceInPips,
    int64 totalAccountValueInPips,
    address wallet,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal returns (int64 quoteQuantityInPips) {
    Balance storage balance = loadBalanceStructAndMigrateIfNeeded(self, wallet, market.baseAssetSymbol);
    int64 positionSizeInPips = balance.balanceInPips;

    Market memory marketWithOverrides = market.loadMarketWithOverridesForWallet(
      exitFundWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    quoteQuantityInPips = LiquidationValidations.calculateExitQuoteQuantity(
      balance.costBasisInPips,
      indexPriceInPips,
      positionSizeInPips,
      totalAccountValueInPips
    );

    balance.balanceInPips = 0;
    balance.costBasisInPips = 0;
    _updateOpenPositionsForWallet(
      wallet,
      market.baseAssetSymbol,
      balance.balanceInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    balance = loadBalanceStructAndMigrateIfNeeded(self, exitFundWallet, market.baseAssetSymbol);
    _updatePosition(balance, positionSizeInPips, quoteQuantityInPips, marketWithOverrides.maximumPositionSizeInPips);
    _updateOpenPositionsForWallet(
      exitFundWallet,
      market.baseAssetSymbol,
      balance.balanceInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
    );
  }

  // Trading //

  /**
   * @dev Updates buyer, seller, and fee wallet balances for both assets in trade pair according to
   * trade parameters
   */
  function updateForOrderBookTrade(
    Storage storage self,
    ExecuteOrderBookTradeArguments memory arguments,
    Market memory market,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal {
    Balance storage balance;

    (
      int64 buyFeeInPips,
      int64 sellFeeInPips,
      // Use the taker order nonce timestamp as the time of execution
      uint64 executionTimestampInMs
    ) = arguments.orderBookTrade.makerSide == OrderSide.Buy
        ? (
          arguments.orderBookTrade.makerFeeQuantityInPips,
          int64(arguments.orderBookTrade.takerFeeQuantityInPips),
          UUID.getTimestampInMsFromUuidV1(arguments.sell.nonce)
        )
        : (
          int64(arguments.orderBookTrade.takerFeeQuantityInPips),
          arguments.orderBookTrade.makerFeeQuantityInPips,
          UUID.getTimestampInMsFromUuidV1(arguments.buy.nonce)
        );

    // Seller gives base asset including fees
    balance = loadBalanceStructAndMigrateIfNeeded(
      self,
      arguments.sell.wallet,
      arguments.orderBookTrade.baseAssetSymbol
    );
    if (arguments.sell.isReduceOnly) {
      _validatePositionUpdatedTowardsZero(
        balance.balanceInPips,
        balance.balanceInPips - int64(arguments.orderBookTrade.baseQuantityInPips)
      );
    }
    _subtractFromPosition(
      balance,
      arguments.orderBookTrade.baseQuantityInPips,
      arguments.orderBookTrade.quoteQuantityInPips,
      market
        .loadMarketWithOverridesForWallet(arguments.sell.wallet, marketOverridesByBaseAssetSymbolAndWallet)
        .maximumPositionSizeInPips
    );
    balance.lastUpdateTimestampInMs = executionTimestampInMs;
    _updateOpenPositionsForWallet(
      arguments.sell.wallet,
      arguments.orderBookTrade.baseAssetSymbol,
      balance.balanceInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Buyer receives base asset
    balance = loadBalanceStructAndMigrateIfNeeded(self, arguments.buy.wallet, arguments.orderBookTrade.baseAssetSymbol);
    if (arguments.buy.isReduceOnly) {
      _validatePositionUpdatedTowardsZero(
        balance.balanceInPips,
        balance.balanceInPips + int64(arguments.orderBookTrade.baseQuantityInPips)
      );
    }
    _addToPosition(
      balance,
      arguments.orderBookTrade.baseQuantityInPips,
      arguments.orderBookTrade.quoteQuantityInPips,
      market
        .loadMarketWithOverridesForWallet(arguments.buy.wallet, marketOverridesByBaseAssetSymbolAndWallet)
        .maximumPositionSizeInPips
    );
    balance.lastUpdateTimestampInMs = executionTimestampInMs;
    _updateOpenPositionsForWallet(
      arguments.buy.wallet,
      arguments.orderBookTrade.baseAssetSymbol,
      balance.balanceInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Buyer gives quote asset including fees
    balance = loadBalanceStructAndMigrateIfNeeded(
      self,
      arguments.buy.wallet,
      arguments.orderBookTrade.quoteAssetSymbol
    );
    balance.balanceInPips -= int64(arguments.orderBookTrade.quoteQuantityInPips) + buyFeeInPips;

    // Seller receives quote asset minus fees
    balance = loadBalanceStructAndMigrateIfNeeded(
      self,
      arguments.sell.wallet,
      arguments.orderBookTrade.quoteAssetSymbol
    );
    balance.balanceInPips += int64(arguments.orderBookTrade.quoteQuantityInPips) - sellFeeInPips;

    // Maker fee to fee wallet
    balance = loadBalanceStructAndMigrateIfNeeded(self, arguments.feeWallet, arguments.orderBookTrade.quoteAssetSymbol);
    balance.balanceInPips +=
      arguments.orderBookTrade.makerFeeQuantityInPips +
      int64(arguments.orderBookTrade.takerFeeQuantityInPips);
  }

  // Withdrawing //

  function updateForWithdrawal(
    Storage storage self,
    Withdrawal memory withdrawal,
    string memory assetSymbol,
    address feeWallet
  ) internal returns (int64 newExchangeBalanceInPips) {
    Balance storage balance;

    balance = loadBalanceStructAndMigrateIfNeeded(self, withdrawal.wallet, assetSymbol);
    // Reverts if balance is overdrawn
    balance.balanceInPips -= int64(withdrawal.grossQuantityInPips);
    newExchangeBalanceInPips = balance.balanceInPips;

    if (withdrawal.gasFeeInPips > 0) {
      balance = loadBalanceStructAndMigrateIfNeeded(self, feeWallet, assetSymbol);

      balance.balanceInPips += int64(withdrawal.gasFeeInPips);
    }
  }

  // Accessors //

  function loadBalanceFromMigrationSourceIfNeeded(
    Storage storage self,
    address wallet,
    string memory assetSymbol
  ) internal view returns (int64) {
    return loadBalanceStructFromMigrationSourceIfNeeded(self, wallet, assetSymbol).balanceInPips;
  }

  function loadBalanceStructFromMigrationSourceIfNeeded(
    Storage storage self,
    address wallet,
    string memory assetSymbol
  ) internal view returns (Balance memory) {
    Balance memory balance = self.balancesByWalletAssetPair[wallet][assetSymbol];

    if (!balance.isMigrated && address(self.migrationSource) != address(0x0)) {
      balance = self.migrationSource.loadBalanceStructBySymbol(wallet, assetSymbol);
    }

    return balance;
  }

  // Lazy updates //

  function loadBalanceAndMigrateIfNeeded(
    Storage storage self,
    address wallet,
    string memory assetSymbol
  ) internal returns (int64) {
    return loadBalanceStructAndMigrateIfNeeded(self, wallet, assetSymbol).balanceInPips;
  }

  function loadBalanceStructAndMigrateIfNeeded(
    Storage storage self,
    address wallet,
    string memory assetSymbol
  ) internal returns (Balance storage) {
    Balance storage balance = self.balancesByWalletAssetPair[wallet][assetSymbol];

    Balance memory migratedBalance;
    if (!balance.isMigrated && address(self.migrationSource) != address(0x0)) {
      migratedBalance = self.migrationSource.loadBalanceStructBySymbol(wallet, assetSymbol);
      balance.isMigrated = true;
      balance.balanceInPips = migratedBalance.balanceInPips;
      balance.lastUpdateTimestampInMs = migratedBalance.lastUpdateTimestampInMs;
    }

    return balance;
  }

  // Position updates //

  function _updatePosition(
    Balance storage balance,
    int64 baseQuantityInPips,
    int64 quoteQuantityInPips,
    uint64 maximumPositionSizeInPips
  ) private {
    if (baseQuantityInPips > 0) {
      _addToPosition(balance, Math.abs(baseQuantityInPips), Math.abs(quoteQuantityInPips), maximumPositionSizeInPips);
    } else {
      _subtractFromPosition(
        balance,
        Math.abs(baseQuantityInPips),
        Math.abs(quoteQuantityInPips),
        maximumPositionSizeInPips
      );
    }
  }

  function _addToPosition(
    Balance storage balance,
    uint64 baseQuantityInPips,
    uint64 quoteQuantityInPips,
    uint64 maximumPositionSizeInPips
  ) private {
    int64 newBalanceInPips = balance.balanceInPips + int64(baseQuantityInPips);
    require(Math.abs(newBalanceInPips) <= maximumPositionSizeInPips, "Max position size exceeded");

    if (balance.balanceInPips >= 0) {
      // Increase position
      balance.costBasisInPips += int64(quoteQuantityInPips);
    } else if (balance.balanceInPips + int64(baseQuantityInPips) > 0) {
      /*
       * Going from negative to positive. Only the portion of the quote qty
       * that contributed to the new, positive balance is its cost.
       */
      balance.costBasisInPips = Math.multiplyPipsByFraction(
        int64(quoteQuantityInPips),
        newBalanceInPips,
        int64(baseQuantityInPips)
      );
    } else {
      // Reduce cost basis proportional to reduction of position
      balance.costBasisInPips += Math.multiplyPipsByFraction(
        balance.costBasisInPips,
        int64(baseQuantityInPips),
        balance.balanceInPips
      );
    }

    balance.balanceInPips = newBalanceInPips;
  }

  function _subtractFromPosition(
    Balance storage balance,
    uint64 baseQuantityInPips,
    uint64 quoteQuantityInPips,
    uint64 maximumPositionSizeInPips
  ) private {
    int64 newBalanceInPips = balance.balanceInPips - int64(baseQuantityInPips);
    require(Math.abs(newBalanceInPips) <= maximumPositionSizeInPips, "Max position size exceeded");

    if (balance.balanceInPips <= 0) {
      // Increase position
      balance.costBasisInPips -= int64(quoteQuantityInPips);
    } else if (balance.balanceInPips - int64(baseQuantityInPips) < 0) {
      /*
       * Going from negative to positive. Only the portion of the quote qty
       * that contributed to the new, positive balance is its cost.
       */
      balance.costBasisInPips = Math.multiplyPipsByFraction(
        int64(quoteQuantityInPips),
        newBalanceInPips,
        int64(baseQuantityInPips)
      );
    } else {
      // Reduce cost basis proportional to reduction of position
      balance.costBasisInPips -= Math.multiplyPipsByFraction(
        balance.costBasisInPips,
        int64(baseQuantityInPips),
        balance.balanceInPips
      );
    }

    balance.balanceInPips = newBalanceInPips;
  }

  function _updateOpenPositionsForWallet(
    address wallet,
    string memory assetSymbol,
    int64 balanceInPips,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet
  ) private {
    baseAssetSymbolsWithOpenPositionsByWallet[wallet] = balanceInPips == 0
      ? baseAssetSymbolsWithOpenPositionsByWallet[wallet].remove(assetSymbol)
      : baseAssetSymbolsWithOpenPositionsByWallet[wallet].insertSorted(assetSymbol);
  }

  function _updatePositionForDeleverageOrLiquidation(
    Storage storage self,
    bool isDeleverage,
    int64 baseQuantityInPips,
    address counterpartyWallet,
    address liquidatingWallet,
    Market memory market,
    int64 quoteQuantityInPips,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    Balance storage balance;

    // Wallet position decreases by specified base quantity
    balance = loadBalanceStructAndMigrateIfNeeded(self, liquidatingWallet, market.baseAssetSymbol);
    _validatePositionUpdatedTowardsZero(balance.balanceInPips, balance.balanceInPips + baseQuantityInPips);
    _updatePosition(
      balance,
      baseQuantityInPips,
      quoteQuantityInPips,
      market
        .loadMarketWithOverridesForWallet(liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
        .maximumPositionSizeInPips
    );
    _updateOpenPositionsForWallet(
      liquidatingWallet,
      market.baseAssetSymbol,
      balance.balanceInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Counterparty position takes on specified base quantity
    balance = loadBalanceStructAndMigrateIfNeeded(self, counterpartyWallet, market.baseAssetSymbol);
    if (isDeleverage) {
      _validatePositionUpdatedTowardsZero(balance.balanceInPips, balance.balanceInPips - baseQuantityInPips);
    }
    _updatePosition(
      balance,
      -1 * baseQuantityInPips,
      quoteQuantityInPips,
      market
        .loadMarketWithOverridesForWallet(counterpartyWallet, marketOverridesByBaseAssetSymbolAndWallet)
        .maximumPositionSizeInPips
    );
    _updateOpenPositionsForWallet(
      counterpartyWallet,
      market.baseAssetSymbol,
      balance.balanceInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Wallet receives or gives quote if long or short respectively
    balance = loadBalanceStructAndMigrateIfNeeded(self, liquidatingWallet, Constants.QUOTE_ASSET_SYMBOL);
    balance.balanceInPips += quoteQuantityInPips;
    // Insurance or counterparty receives or gives quote if wallet short or long respectively
    balance = loadBalanceStructAndMigrateIfNeeded(self, counterpartyWallet, Constants.QUOTE_ASSET_SYMBOL);
    balance.balanceInPips -= quoteQuantityInPips;
  }

  function _validatePositionUpdatedTowardsZero(
    int64 originalPositionSizeInPips,
    int64 newPositionSizeInPips
  ) private pure {
    bool isValid = originalPositionSizeInPips < 0
      ? newPositionSizeInPips > originalPositionSizeInPips && newPositionSizeInPips <= 0
      : newPositionSizeInPips < originalPositionSizeInPips && newPositionSizeInPips >= 0;
    require(isValid, "Position must move toward zero");
  }
}
