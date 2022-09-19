// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { Constants } from './Constants.sol';
import { IExchange } from './Interfaces.sol';
import { LiquidationValidations } from './LiquidationValidations.sol';
import { MarketOverrides } from './MarketOverrides.sol';
import { Math } from './Math.sol';
import { OrderSide } from './Enums.sol';
import { SortedStringSet } from './SortedStringSet.sol';
import { UUID } from './UUID.sol';
import { Balance, ExecuteOrderBookTradeArguments, Market, Order, OrderBookTrade, Withdrawal } from './Structs.sol';

import 'hardhat/console.sol';

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
    address walletAddress,
    string memory assetSymbol,
    uint64 quantityInPips
  ) internal returns (int64 newBalanceInPips) {
    Balance storage balance = loadBalanceAndMigrateIfNeeded(
      self,
      walletAddress,
      assetSymbol
    );
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
    string memory quoteAssetSymbol,
    int64 quoteQuantityInPips,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal {
    updatePositionForDeleverageOrLiquidation(
      self,
      true,
      baseQuantityInPips,
      counterpartyWallet,
      liquidatingWallet,
      market,
      quoteAssetSymbol,
      quoteQuantityInPips,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function updatePositionForLiquidation(
    Storage storage self,
    int64 baseQuantityInPips,
    address counterpartyWallet,
    address liquidatingWallet,
    Market memory market,
    string memory quoteAssetSymbol,
    int64 quoteQuantityInPips,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal {
    updatePositionForDeleverageOrLiquidation(
      self,
      false,
      baseQuantityInPips,
      counterpartyWallet,
      liquidatingWallet,
      market,
      quoteAssetSymbol,
      quoteQuantityInPips,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function updatePositionForDeleverageOrLiquidation(
    Storage storage self,
    bool isDeleverage,
    int64 baseQuantityInPips,
    address counterpartyWallet,
    address liquidatingWallet,
    Market memory market,
    string memory quoteAssetSymbol,
    int64 quoteQuantityInPips,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    Balance storage balance;

    // Wallet position decreases by specified base quantity
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      liquidatingWallet,
      market.baseAssetSymbol
    );
    validatePositionUpdatedTowardsZero(
      balance.balanceInPips,
      balance.balanceInPips - baseQuantityInPips
    );
    updatePosition(
      balance,
      -1 * baseQuantityInPips,
      quoteQuantityInPips,
      market
        .loadMarketWithOverridesForWallet(
          liquidatingWallet,
          marketOverridesByBaseAssetSymbolAndWallet
        )
        .maximumPositionSizeInPips
    );
    updateOpenPositionsForWallet(
      liquidatingWallet,
      market.baseAssetSymbol,
      balance.balanceInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Counterparty position takes on specified base quantity
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      counterpartyWallet,
      market.baseAssetSymbol
    );
    if (isDeleverage) {
      validatePositionUpdatedTowardsZero(
        balance.balanceInPips,
        balance.balanceInPips + baseQuantityInPips
      );
    }
    updatePosition(
      balance,
      baseQuantityInPips,
      quoteQuantityInPips,
      market
        .loadMarketWithOverridesForWallet(
          counterpartyWallet,
          marketOverridesByBaseAssetSymbolAndWallet
        )
        .maximumPositionSizeInPips
    );
    updateOpenPositionsForWallet(
      counterpartyWallet,
      market.baseAssetSymbol,
      balance.balanceInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Wallet receives or gives quote if long or short respectively
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      liquidatingWallet,
      quoteAssetSymbol
    );
    balance.balanceInPips += quoteQuantityInPips;
    // Insurance receives or gives quote if wallet short or long respectively
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      counterpartyWallet,
      quoteAssetSymbol
    );
    balance.balanceInPips -= quoteQuantityInPips;
  }

  function updateQuoteForLiquidation(
    Storage storage self,
    string memory quoteAssetSymbol,
    address counterpartyWallet,
    address liquidatingWallet
  ) internal {
    Balance storage balance;

    // Liquidating wallet quote balance goes to zero
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      liquidatingWallet,
      quoteAssetSymbol
    );
    int64 quoteQuantityInPips = balance.balanceInPips;
    balance.balanceInPips = 0;
    // Counterparty wallet takes any remaining quote from liquidating wallet
    if (quoteQuantityInPips != 0) {
      balance = loadBalanceAndMigrateIfNeeded(
        self,
        counterpartyWallet,
        quoteAssetSymbol
      );
      balance.balanceInPips += quoteQuantityInPips;
    }
  }

  // Wallet exits //

  function updateForExit(
    Storage storage self,
    address exitFundWallet,
    Market memory market,
    uint64 oraclePriceInPips,
    int64 totalAccountValueInPips,
    uint64 totalMaintenanceMarginRequirementInPips,
    address wallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal returns (int64 quoteQuantityInPips) {
    Balance storage balance = loadBalanceAndMigrateIfNeeded(
      self,
      wallet,
      market.baseAssetSymbol
    );
    int64 positionSizeInPips = balance.balanceInPips;

    Market memory marketWithOverrides = market.loadMarketWithOverridesForWallet(
      exitFundWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    quoteQuantityInPips = LiquidationValidations
      .calculateExitQuoteQuantityInPips(
        balance.costBasisInPips,
        marketWithOverrides.maintenanceMarginFractionInPips,
        oraclePriceInPips,
        positionSizeInPips,
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips
      );

    balance.balanceInPips = 0;
    balance.costBasisInPips = 0;

    balance = loadBalanceAndMigrateIfNeeded(
      self,
      exitFundWallet,
      market.baseAssetSymbol
    );
    updatePosition(
      balance,
      positionSizeInPips,
      quoteQuantityInPips,
      marketWithOverrides.maximumPositionSizeInPips
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
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
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
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      arguments.sell.walletAddress,
      arguments.orderBookTrade.baseAssetSymbol
    );
    subtractFromPosition(
      balance,
      arguments.orderBookTrade.baseQuantityInPips,
      arguments.orderBookTrade.quoteQuantityInPips,
      market
        .loadMarketWithOverridesForWallet(
          arguments.sell.walletAddress,
          marketOverridesByBaseAssetSymbolAndWallet
        )
        .maximumPositionSizeInPips
    );
    balance.lastUpdateTimestampInMs = executionTimestampInMs;
    updateOpenPositionsForWallet(
      arguments.sell.walletAddress,
      arguments.orderBookTrade.baseAssetSymbol,
      balance.balanceInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
    );
    // Buyer receives base asset minus fees
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      arguments.buy.walletAddress,
      arguments.orderBookTrade.baseAssetSymbol
    );
    addToPosition(
      balance,
      arguments.orderBookTrade.baseQuantityInPips,
      arguments.orderBookTrade.quoteQuantityInPips,
      market
        .loadMarketWithOverridesForWallet(
          arguments.buy.walletAddress,
          marketOverridesByBaseAssetSymbolAndWallet
        )
        .maximumPositionSizeInPips
    );
    balance.lastUpdateTimestampInMs = executionTimestampInMs;
    updateOpenPositionsForWallet(
      arguments.buy.walletAddress,
      arguments.orderBookTrade.baseAssetSymbol,
      balance.balanceInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Buyer gives quote asset including fees
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      arguments.buy.walletAddress,
      arguments.orderBookTrade.quoteAssetSymbol
    );
    balance.balanceInPips -=
      int64(arguments.orderBookTrade.quoteQuantityInPips) +
      buyFeeInPips;

    // Seller receives quote asset minus fees
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      arguments.sell.walletAddress,
      arguments.orderBookTrade.quoteAssetSymbol
    );
    balance.balanceInPips +=
      int64(arguments.orderBookTrade.quoteQuantityInPips) -
      sellFeeInPips;

    // Maker fee to fee wallet
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      arguments.feeWallet,
      arguments.orderBookTrade.quoteAssetSymbol
    );
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

    balance = loadBalanceAndMigrateIfNeeded(
      self,
      withdrawal.walletAddress,
      assetSymbol
    );
    // Reverts if balance is overdrawn
    balance.balanceInPips -= int64(withdrawal.grossQuantityInPips);
    newExchangeBalanceInPips = balance.balanceInPips;

    if (withdrawal.gasFeeInPips > 0) {
      balance = loadBalanceAndMigrateIfNeeded(self, feeWallet, assetSymbol);

      balance.balanceInPips += int64(withdrawal.gasFeeInPips);
    }
  }

  // Accessors //

  function loadBalanceFromMigrationSourceIfNeeded(
    Storage storage self,
    address wallet,
    string memory assetSymbol
  ) internal view returns (Balance memory) {
    Balance memory balance = self.balancesByWalletAssetPair[wallet][
      assetSymbol
    ];

    if (!balance.isMigrated && address(self.migrationSource) != address(0x0)) {
      balance = self.migrationSource.loadBalanceBySymbol(wallet, assetSymbol);
    }

    return balance;
  }

  function loadBalanceInPipsFromMigrationSourceIfNeeded(
    Storage storage self,
    address wallet,
    string memory assetSymbol
  ) internal view returns (int64) {
    Balance memory balance = loadBalanceFromMigrationSourceIfNeeded(
      self,
      wallet,
      assetSymbol
    );

    return balance.balanceInPips;
  }

  // Lazy updates //

  function loadBalanceAndMigrateIfNeeded(
    Storage storage self,
    address wallet,
    string memory assetSymbol
  ) internal returns (Balance storage) {
    Balance storage balance = self.balancesByWalletAssetPair[wallet][
      assetSymbol
    ];

    Balance memory migratedBalance;
    if (!balance.isMigrated && address(self.migrationSource) != address(0x0)) {
      migratedBalance = self.migrationSource.loadBalanceBySymbol(
        wallet,
        assetSymbol
      );
      balance.isMigrated = true;
      balance.balanceInPips = migratedBalance.balanceInPips;
      balance.lastUpdateTimestampInMs = migratedBalance.lastUpdateTimestampInMs;
    }

    return balance;
  }

  // Position updates //

  function updatePosition(
    Balance storage balance,
    int64 baseQuantityInPips,
    int64 quoteQuantityInPips,
    uint64 maximumPositionSizeInPips
  ) internal {
    if (baseQuantityInPips > 0) {
      addToPosition(
        balance,
        Math.abs(baseQuantityInPips),
        Math.abs(quoteQuantityInPips),
        maximumPositionSizeInPips
      );
    } else {
      subtractFromPosition(
        balance,
        Math.abs(baseQuantityInPips),
        Math.abs(quoteQuantityInPips),
        maximumPositionSizeInPips
      );
    }
  }

  function addToPosition(
    Balance storage balance,
    uint64 baseQuantityInPips,
    uint64 quoteQuantityInPips,
    uint64 maximumPositionSizeInPips
  ) internal {
    int64 newBalanceInPips = balance.balanceInPips + int64(baseQuantityInPips);
    require(
      Math.abs(newBalanceInPips) <= maximumPositionSizeInPips,
      'Max position size exceeded'
    );

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

  function subtractFromPosition(
    Balance storage balance,
    uint64 baseQuantityInPips,
    uint64 quoteQuantityInPips,
    uint64 maximumPositionSizeInPips
  ) internal {
    int64 newBalanceInPips = balance.balanceInPips - int64(baseQuantityInPips);
    require(
      Math.abs(newBalanceInPips) <= maximumPositionSizeInPips,
      'Max position size exceeded'
    );

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

  function updateOpenPositionsForWallet(
    address wallet,
    string memory assetSymbol,
    int64 balanceInPips,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet
  ) internal {
    baseAssetSymbolsWithOpenPositionsByWallet[wallet] = balanceInPips == 0
      ? baseAssetSymbolsWithOpenPositionsByWallet[wallet].remove(assetSymbol)
      : baseAssetSymbolsWithOpenPositionsByWallet[wallet].insertSorted(
        assetSymbol
      );
  }

  function validatePositionUpdatedTowardsZero(
    int64 originalPositionSizeInPips,
    int64 newPositionSizeInPips
  ) private pure {
    bool isValid = originalPositionSizeInPips < 0
      ? newPositionSizeInPips > originalPositionSizeInPips &&
        newPositionSizeInPips <= 0
      : newPositionSizeInPips < originalPositionSizeInPips &&
        newPositionSizeInPips >= 0;
    require(isValid, 'Position must move toward zero');
  }
}
