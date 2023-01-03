// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { Constants } from "./Constants.sol";
import { IExchange } from "./Interfaces.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Math } from "./Math.sol";
import { OrderSide } from "./Enums.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { UUID } from "./UUID.sol";
import { Balance, ExecuteOrderBookTradeArguments, Market, MarketOverrides, Order, OrderBookTrade, Withdrawal } from "./Structs.sol";

library BalanceTracking {
  using MarketHelper for Market;
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
    uint64 quantity
  ) internal returns (int64 newBalance) {
    Balance storage balance = loadBalanceStructAndMigrateIfNeeded(self, wallet, assetSymbol);
    balance.balance += int64(quantity);

    return balance.balance;
  }

  // Liquidation //

  function updatePositionForDeleverage(
    Storage storage self,
    int64 baseQuantity,
    address counterpartyWallet,
    address liquidatingWallet,
    Market memory market,
    int64 quoteQuantity,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal {
    _updatePositionsForDeleverageOrLiquidation(
      self,
      true,
      baseQuantity,
      counterpartyWallet,
      liquidatingWallet,
      market,
      quoteQuantity,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function updatePositionForLiquidation(
    Storage storage self,
    int64 positionSize,
    address counterpartyWallet,
    address liquidatingWallet,
    Market memory market,
    uint64 quoteQuantity,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal {
    _updatePositionsForDeleverageOrLiquidation(
      self,
      false,
      -1 * positionSize,
      counterpartyWallet,
      liquidatingWallet,
      market,
      quoteQuantity,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function updatePositionForDeactivatedMarketLiquidation(
    Storage storage self,
    string memory baseAssetSymbol,
    address liquidatingWallet,
    int64 quoteQuantity,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet
  ) internal {
    Balance storage balance;

    // Zero out wallet position for market
    balance = loadBalanceStructAndMigrateIfNeeded(self, liquidatingWallet, baseAssetSymbol);
    balance.balance = 0;
    balance.costBasis = 0;

    _updateOpenPositionsForWallet(
      liquidatingWallet,
      baseAssetSymbol,
      balance.balance,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Wallet receives or gives quote if long or short respectively
    balance = loadBalanceStructAndMigrateIfNeeded(self, liquidatingWallet, Constants.QUOTE_ASSET_SYMBOL);
    balance.balance += quoteQuantity;
  }

  function updateQuoteForLiquidation(
    Storage storage self,
    address counterpartyWallet,
    address liquidatingWallet
  ) internal {
    Balance storage balance;

    // Liquidating wallet quote balance goes to zero
    balance = loadBalanceStructAndMigrateIfNeeded(self, liquidatingWallet, Constants.QUOTE_ASSET_SYMBOL);
    int64 quoteQuantity = balance.balance;
    balance.balance = 0;
    // Counterparty wallet takes any remaining quote from liquidating wallet
    if (quoteQuantity != 0) {
      balance = loadBalanceStructAndMigrateIfNeeded(self, counterpartyWallet, Constants.QUOTE_ASSET_SYMBOL);
      balance.balance += quoteQuantity;
    }
  }

  // Wallet exits //

  function updateForExit(
    Storage storage self,
    address exitFundWallet,
    uint64 indexPrice,
    Market memory market,
    uint64 maintenanceMarginFraction,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement,
    address wallet,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal returns (int64 quoteQuantity) {
    // Calculate amount of quote to close position
    Balance storage balance = loadBalanceStructAndMigrateIfNeeded(self, wallet, market.baseAssetSymbol);

    int64 positionSize = balance.balance;
    quoteQuantity = int64(
      LiquidationValidations.calculateExitQuoteQuantity(
        balance.costBasis,
        indexPrice,
        maintenanceMarginFraction,
        positionSize,
        totalAccountValue,
        totalMaintenanceMarginRequirement
      )
    );

    // Zero out wallet position for market
    balance.balance = 0;
    balance.costBasis = 0;
    _updateOpenPositionsForWallet(
      wallet,
      market.baseAssetSymbol,
      balance.balance,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Exit Fund wallet assumes wallet's position
    Market memory marketWithExitFundOverrides = market.loadMarketWithOverridesForWallet(
      exitFundWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );
    balance = loadBalanceStructAndMigrateIfNeeded(self, exitFundWallet, market.baseAssetSymbol);
    _updatePosition(
      balance,
      positionSize,
      quoteQuantity,
      marketWithExitFundOverrides.overridableFields.maximumPositionSize
    );
    if (balance.lastUpdateTimestampInMs == 0) {
      balance.lastUpdateTimestampInMs = lastFundingRatePublishTimestampInMsByBaseAssetSymbol[market.baseAssetSymbol];
    }
    _updateOpenPositionsForWallet(
      exitFundWallet,
      market.baseAssetSymbol,
      balance.balance,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // The Exit Fund quote balance is not updated here, but instead is updated a single time in the calling function
    // after summing the quote quantities needed to close each wallet position
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
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal {
    Balance storage balance;

    // Opening a position in a market requires a funding multiplier already be present in order to have a starting
    // timestamp (from which multiplier array index and offset are calculated) for the wallet from which to apply
    // funding payments
    uint64 lastFundingRateTimestampInMs = lastFundingRatePublishTimestampInMsByBaseAssetSymbol[market.baseAssetSymbol];
    require(lastFundingRateTimestampInMs > 0, "Must publish funding multiplier before opening position");

    (
      int64 buyFee,
      int64 sellFee // Use the taker order nonce timestamp as the time of execution
    ) = arguments.orderBookTrade.makerSide == OrderSide.Buy
        ? (arguments.orderBookTrade.makerFeeQuantity, int64(arguments.orderBookTrade.takerFeeQuantity))
        : (int64(arguments.orderBookTrade.takerFeeQuantity), arguments.orderBookTrade.makerFeeQuantity);

    // Seller gives base asset including fees
    balance = loadBalanceStructAndMigrateIfNeeded(
      self,
      arguments.sell.wallet,
      arguments.orderBookTrade.baseAssetSymbol
    );
    if (arguments.sell.isReduceOnly) {
      _validatePositionUpdatedTowardsZero(
        balance.balance,
        balance.balance - int64(arguments.orderBookTrade.baseQuantity)
      );
    }
    _subtractFromPosition(
      balance,
      arguments.orderBookTrade.baseQuantity,
      arguments.orderBookTrade.quoteQuantity,
      market
        .loadMarketWithOverridesForWallet(arguments.sell.wallet, marketOverridesByBaseAssetSymbolAndWallet)
        .overridableFields
        .maximumPositionSize
    );
    if (balance.lastUpdateTimestampInMs == 0) {
      balance.lastUpdateTimestampInMs = lastFundingRateTimestampInMs;
    }
    _updateOpenPositionsForWallet(
      arguments.sell.wallet,
      arguments.orderBookTrade.baseAssetSymbol,
      balance.balance,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Buyer receives base asset
    balance = loadBalanceStructAndMigrateIfNeeded(self, arguments.buy.wallet, arguments.orderBookTrade.baseAssetSymbol);
    if (arguments.buy.isReduceOnly) {
      _validatePositionUpdatedTowardsZero(
        balance.balance,
        balance.balance + int64(arguments.orderBookTrade.baseQuantity)
      );
    }
    _addToPosition(
      balance,
      arguments.orderBookTrade.baseQuantity,
      arguments.orderBookTrade.quoteQuantity,
      market
        .loadMarketWithOverridesForWallet(arguments.buy.wallet, marketOverridesByBaseAssetSymbolAndWallet)
        .overridableFields
        .maximumPositionSize
    );
    if (balance.lastUpdateTimestampInMs == 0) {
      balance.lastUpdateTimestampInMs = lastFundingRateTimestampInMs;
    }
    _updateOpenPositionsForWallet(
      arguments.buy.wallet,
      arguments.orderBookTrade.baseAssetSymbol,
      balance.balance,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Buyer gives quote asset including fees
    balance = loadBalanceStructAndMigrateIfNeeded(
      self,
      arguments.buy.wallet,
      arguments.orderBookTrade.quoteAssetSymbol
    );
    balance.balance -= int64(arguments.orderBookTrade.quoteQuantity) + buyFee;

    // Seller receives quote asset minus fees
    balance = loadBalanceStructAndMigrateIfNeeded(
      self,
      arguments.sell.wallet,
      arguments.orderBookTrade.quoteAssetSymbol
    );
    balance.balance += int64(arguments.orderBookTrade.quoteQuantity) - sellFee;

    // Maker fee to fee wallet
    balance = loadBalanceStructAndMigrateIfNeeded(self, arguments.feeWallet, arguments.orderBookTrade.quoteAssetSymbol);
    balance.balance += buyFee + sellFee;
  }

  // Withdrawing //

  function updateForWithdrawal(
    Storage storage self,
    Withdrawal memory withdrawal,
    string memory assetSymbol,
    address feeWallet
  ) internal returns (int64 newExchangeBalance) {
    Balance storage balance;

    balance = loadBalanceStructAndMigrateIfNeeded(self, withdrawal.wallet, assetSymbol);
    // Reverts if balance is overdrawn
    balance.balance -= int64(withdrawal.grossQuantity);
    newExchangeBalance = balance.balance;

    if (withdrawal.gasFee > 0) {
      balance = loadBalanceStructAndMigrateIfNeeded(self, feeWallet, assetSymbol);

      balance.balance += int64(withdrawal.gasFee);
    }
  }

  // Accessors //

  function loadBalanceFromMigrationSourceIfNeeded(
    Storage storage self,
    address wallet,
    string memory assetSymbol
  ) internal view returns (int64) {
    return loadBalanceStructFromMigrationSourceIfNeeded(self, wallet, assetSymbol).balance;
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
    return loadBalanceStructAndMigrateIfNeeded(self, wallet, assetSymbol).balance;
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
      balance.balance = migratedBalance.balance;
      balance.lastUpdateTimestampInMs = migratedBalance.lastUpdateTimestampInMs;
    }

    return balance;
  }

  // Position updates //

  function _updatePosition(
    Balance storage balance,
    int64 baseQuantity,
    int64 quoteQuantity,
    uint64 maximumPositionSize
  ) private {
    if (baseQuantity > 0) {
      _addToPosition(balance, Math.abs(baseQuantity), Math.abs(quoteQuantity), maximumPositionSize);
    } else {
      _subtractFromPosition(balance, Math.abs(baseQuantity), Math.abs(quoteQuantity), maximumPositionSize);
    }
  }

  function _addToPosition(
    Balance storage balance,
    uint64 baseQuantity,
    uint64 quoteQuantity,
    uint64 maximumPositionSize
  ) private {
    int64 newBalance = balance.balance + int64(baseQuantity);
    require(Math.abs(newBalance) <= maximumPositionSize, "Max position size exceeded");

    if (balance.balance >= 0) {
      // Increase position
      balance.costBasis += int64(quoteQuantity);
    } else if (newBalance > 0) {
      /*
       * Going from negative to positive. Only the portion of the quote qty
       * that contributed to the new, positive balance is its cost.
       */
      balance.costBasis = Math.multiplyPipsByFraction(int64(quoteQuantity), newBalance, int64(baseQuantity));
    } else {
      // Reduce cost basis proportional to reduction of position
      balance.costBasis += Math.multiplyPipsByFraction(balance.costBasis, int64(baseQuantity), balance.balance);
    }

    balance.balance = newBalance;
  }

  function _subtractFromPosition(
    Balance storage balance,
    uint64 baseQuantity,
    uint64 quoteQuantity,
    uint64 maximumPositionSize
  ) private {
    int64 newBalance = balance.balance - int64(baseQuantity);
    require(Math.abs(newBalance) <= maximumPositionSize, "Max position size exceeded");

    if (balance.balance <= 0) {
      // Increase position
      balance.costBasis -= int64(quoteQuantity);
    } else if (newBalance < 0) {
      /*
       * Going from positive to negative. Only the portion of the quote qty
       * that contributed to the new, positive balance is its cost.
       */
      balance.costBasis = Math.multiplyPipsByFraction(int64(quoteQuantity), newBalance, int64(baseQuantity));
    } else {
      // Reduce cost basis proportional to reduction of position
      balance.costBasis -= Math.multiplyPipsByFraction(balance.costBasis, int64(baseQuantity), balance.balance);
    }

    balance.balance = newBalance;
  }

  function _updateOpenPositionsForWallet(
    address wallet,
    string memory assetSymbol,
    int64 balance,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet
  ) private {
    baseAssetSymbolsWithOpenPositionsByWallet[wallet] = balance == 0
      ? baseAssetSymbolsWithOpenPositionsByWallet[wallet].remove(assetSymbol)
      : baseAssetSymbolsWithOpenPositionsByWallet[wallet].insertSorted(assetSymbol);
  }

  function _updatePositionsForDeleverageOrLiquidation(
    Storage storage self,
    bool isDeleverage,
    int64 baseQuantity,
    address counterpartyWallet,
    address liquidatingWallet,
    Market memory market,
    int64 quoteQuantity,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    Balance storage balance;

    uint64 lastFundingRateTimestampInMs = lastFundingRatePublishTimestampInMsByBaseAssetSymbol[market.baseAssetSymbol];

    // Wallet position decreases by specified base quantity
    balance = loadBalanceStructAndMigrateIfNeeded(self, liquidatingWallet, market.baseAssetSymbol);
    _validatePositionUpdatedTowardsZero(balance.balance, balance.balance + baseQuantity);
    _updatePosition(
      balance,
      baseQuantity,
      quoteQuantity,
      market
        .loadMarketWithOverridesForWallet(liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
        .overridableFields
        .maximumPositionSize
    );
    if (balance.lastUpdateTimestampInMs == 0) {
      balance.lastUpdateTimestampInMs = lastFundingRateTimestampInMs;
    }
    _updateOpenPositionsForWallet(
      liquidatingWallet,
      market.baseAssetSymbol,
      balance.balance,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Counterparty position takes on specified base quantity
    balance = loadBalanceStructAndMigrateIfNeeded(self, counterpartyWallet, market.baseAssetSymbol);
    if (isDeleverage) {
      _validatePositionUpdatedTowardsZero(balance.balance, balance.balance - baseQuantity);
    }
    _updatePosition(
      balance,
      -1 * baseQuantity,
      quoteQuantity,
      market
        .loadMarketWithOverridesForWallet(counterpartyWallet, marketOverridesByBaseAssetSymbolAndWallet)
        .overridableFields
        .maximumPositionSize
    );
    if (balance.lastUpdateTimestampInMs == 0) {
      balance.lastUpdateTimestampInMs = lastFundingRateTimestampInMs;
    }
    _updateOpenPositionsForWallet(
      counterpartyWallet,
      market.baseAssetSymbol,
      balance.balance,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Wallet receives or gives quote if long or short respectively
    balance = loadBalanceStructAndMigrateIfNeeded(self, liquidatingWallet, Constants.QUOTE_ASSET_SYMBOL);
    balance.balance += quoteQuantity;
    // Insurance or counterparty receives or gives quote if wallet short or long respectively
    balance = loadBalanceStructAndMigrateIfNeeded(self, counterpartyWallet, Constants.QUOTE_ASSET_SYMBOL);
    balance.balance -= quoteQuantity;
  }

  function _validatePositionUpdatedTowardsZero(int64 originalPositionSize, int64 newPositionSize) private pure {
    bool isValid = originalPositionSize < 0
      ? newPositionSize > originalPositionSize && newPositionSize <= 0
      : newPositionSize < originalPositionSize && newPositionSize >= 0;
    require(isValid, "Position must move toward zero");
  }
}
