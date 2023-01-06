// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { Constants } from "./Constants.sol";
import { IExchange } from "./Interfaces.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Math } from "./Math.sol";
import { OrderSide } from "./Enums.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Balance, ExecuteOrderBookTradeArguments, Market, MarketOverrides, Withdrawal } from "./Structs.sol";

library BalanceTracking {
  using MarketHelper for Market;
  using SortedStringSet for string[];

  struct Storage {
    mapping(address => mapping(string => Balance)) balancesByWalletAssetPair;
    // Predecessor Exchange contract from which to lazily migrate balances
    IExchange migrationSource;
  }

  struct UpdateForExitArguments {
    address exitFundWallet;
    Market market;
    uint64 maintenanceMarginFraction;
    int64 totalAccountValue;
    uint64 totalMaintenanceMarginRequirement;
    address wallet;
  }

  // Depositing //

  function updateForDeposit(
    Storage storage self,
    address wallet,
    string memory assetSymbol,
    uint64 quantity
  ) internal returns (int64 newBalance) {
    Balance storage balanceStruct = loadBalanceStructAndMigrateIfNeeded(self, wallet, assetSymbol);
    balanceStruct.balance += int64(quantity);

    return balanceStruct.balance;
  }

  // Liquidation //

  function updatePositionForDeleverage(
    Storage storage self,
    uint64 baseQuantity,
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
      baseQuantity,
      counterpartyWallet,
      true,
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
    address counterpartyWallet,
    address liquidatingWallet,
    Market memory market,
    int64 positionSize,
    uint64 quoteQuantity,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal {
    _updatePositionsForDeleverageOrLiquidation(
      self,
      Math.abs(positionSize),
      counterpartyWallet,
      false,
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
    uint64 feeQuantity,
    address feeWallet,
    address liquidatingWallet,
    uint64 quoteQuantity,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet
  ) internal {
    Balance storage balanceStruct;

    // Zero out wallet position for market
    balanceStruct = loadBalanceStructAndMigrateIfNeeded(self, liquidatingWallet, baseAssetSymbol);
    balanceStruct.balance = 0;
    balanceStruct.costBasis = 0;

    _updateOpenPositionsForWallet(
      liquidatingWallet,
      baseAssetSymbol,
      balanceStruct.balance,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    balanceStruct = loadBalanceStructAndMigrateIfNeeded(self, liquidatingWallet, Constants.QUOTE_ASSET_SYMBOL);
    if (balanceStruct.balance < 0) {
      // Wallet gives quote including fee if short
      balanceStruct.balance -= int64(quoteQuantity + feeQuantity);
    } else {
      // Wallet receives quote minus fee if long
      balanceStruct.balance += int64(quoteQuantity - feeQuantity);
    }

    // Fee wallet receives fee
    balanceStruct = loadBalanceStructAndMigrateIfNeeded(self, feeWallet, Constants.QUOTE_ASSET_SYMBOL);
    balanceStruct.balance += int64(feeQuantity);
  }

  function updateQuoteForLiquidation(
    Storage storage self,
    address counterpartyWallet,
    address liquidatingWallet
  ) internal {
    Balance storage balanceStruct;

    // Liquidating wallet quote balance goes to zero
    balanceStruct = loadBalanceStructAndMigrateIfNeeded(self, liquidatingWallet, Constants.QUOTE_ASSET_SYMBOL);
    int64 quoteQuantity = balanceStruct.balance;
    balanceStruct.balance = 0;
    // Counterparty wallet takes any remaining quote from liquidating wallet
    if (quoteQuantity != 0) {
      balanceStruct = loadBalanceStructAndMigrateIfNeeded(self, counterpartyWallet, Constants.QUOTE_ASSET_SYMBOL);
      balanceStruct.balance += quoteQuantity;
    }
  }

  // Wallet exits //

  function updateExitFundWalletForExit(
    Storage storage self,
    address exitFundWallet
  ) internal returns (int64 walletQuoteQuantityToWithdraw) {
    Balance storage balanceStruct = loadBalanceStructAndMigrateIfNeeded(
      self,
      exitFundWallet,
      Constants.QUOTE_ASSET_SYMBOL
    );

    walletQuoteQuantityToWithdraw = balanceStruct.balance;
    balanceStruct.balance = 0;
  }

  /**
   * @return The signed change to the EF's quote balance as a result of closing the position. This will be negative for
   * a short position and positive for a long position. This function does not update the EF's quote balance itself;
   * that is left to the calling function so that it can perform a single update with the sum of each position's result
   */
  function updatePositionForExit(
    Storage storage self,
    UpdateForExitArguments memory arguments,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal returns (int64) {
    Balance storage balanceStruct = loadBalanceStructAndMigrateIfNeeded(
      self,
      arguments.wallet,
      arguments.market.baseAssetSymbol
    );
    int64 positionSize = balanceStruct.balance;
    // Calculate amount of quote to close position
    uint64 quoteQuantity = LiquidationValidations.calculateExitQuoteQuantity(
      balanceStruct.costBasis,
      arguments.market.loadOnChainFeedPrice(),
      arguments.maintenanceMarginFraction,
      positionSize,
      arguments.totalAccountValue,
      arguments.totalMaintenanceMarginRequirement
    );

    // Zero out wallet position for market
    balanceStruct.balance = 0;
    balanceStruct.costBasis = 0;
    _updateOpenPositionsForWallet(
      arguments.wallet,
      arguments.market.baseAssetSymbol,
      balanceStruct.balance,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Exit Fund wallet takes on wallet's position
    Market memory marketWithExitFundOverrides = arguments.market.loadMarketWithOverridesForWallet(
      arguments.exitFundWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );
    balanceStruct = loadBalanceStructAndMigrateIfNeeded(
      self,
      arguments.exitFundWallet,
      arguments.market.baseAssetSymbol
    );

    if (positionSize < 0) {
      // Take on short position by subtracting base quantity
      _subtractFromPosition(
        balanceStruct,
        Math.abs(positionSize),
        quoteQuantity,
        marketWithExitFundOverrides.overridableFields.maximumPositionSize
      );
    } else {
      // Take on long position by adding base quantity
      _addToPosition(
        balanceStruct,
        Math.abs(positionSize),
        quoteQuantity,
        marketWithExitFundOverrides.overridableFields.maximumPositionSize
      );
    }
    // If the EF is opening a position in the market for the first time, the position should be updated with the latest
    // published funding rate for that market so that no funding is applied retroactively
    if (balanceStruct.lastUpdateTimestampInMs == 0) {
      balanceStruct.lastUpdateTimestampInMs = lastFundingRatePublishTimestampInMsByBaseAssetSymbol[
        arguments.market.baseAssetSymbol
      ];
    }
    // Update open position tracking for EF in case the position was opened or closed
    _updateOpenPositionsForWallet(
      arguments.exitFundWallet,
      arguments.market.baseAssetSymbol,
      balanceStruct.balance,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Return the change to the EF's quote balance needed to acquire the position. For short positions, the EF
    // receives quote so returns a positive value. For long positions, the EF gives quote and returns a negative value
    return positionSize < 0 ? int64(quoteQuantity) : -1 * int64(quoteQuantity);

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
    Balance storage balanceStruct;

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

    // Seller gives base asset
    balanceStruct = loadBalanceStructAndMigrateIfNeeded(
      self,
      arguments.sell.wallet,
      arguments.orderBookTrade.baseAssetSymbol
    );
    if (arguments.sell.isReduceOnly) {
      _validatePositionUpdatedTowardsZero(
        balanceStruct.balance,
        balanceStruct.balance - int64(arguments.orderBookTrade.baseQuantity)
      );
    }
    _subtractFromPosition(
      balanceStruct,
      arguments.orderBookTrade.baseQuantity,
      arguments.orderBookTrade.quoteQuantity,
      market
        .loadMarketWithOverridesForWallet(arguments.sell.wallet, marketOverridesByBaseAssetSymbolAndWallet)
        .overridableFields
        .maximumPositionSize
    );
    if (balanceStruct.lastUpdateTimestampInMs == 0) {
      balanceStruct.lastUpdateTimestampInMs = lastFundingRateTimestampInMs;
    }
    _updateOpenPositionsForWallet(
      arguments.sell.wallet,
      arguments.orderBookTrade.baseAssetSymbol,
      balanceStruct.balance,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Buyer receives base asset
    balanceStruct = loadBalanceStructAndMigrateIfNeeded(
      self,
      arguments.buy.wallet,
      arguments.orderBookTrade.baseAssetSymbol
    );
    if (arguments.buy.isReduceOnly) {
      _validatePositionUpdatedTowardsZero(
        balanceStruct.balance,
        balanceStruct.balance + int64(arguments.orderBookTrade.baseQuantity)
      );
    }
    _addToPosition(
      balanceStruct,
      arguments.orderBookTrade.baseQuantity,
      arguments.orderBookTrade.quoteQuantity,
      market
        .loadMarketWithOverridesForWallet(arguments.buy.wallet, marketOverridesByBaseAssetSymbolAndWallet)
        .overridableFields
        .maximumPositionSize
    );
    if (balanceStruct.lastUpdateTimestampInMs == 0) {
      balanceStruct.lastUpdateTimestampInMs = lastFundingRateTimestampInMs;
    }
    _updateOpenPositionsForWallet(
      arguments.buy.wallet,
      arguments.orderBookTrade.baseAssetSymbol,
      balanceStruct.balance,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Buyer gives quote asset including fees
    balanceStruct = loadBalanceStructAndMigrateIfNeeded(self, arguments.buy.wallet, Constants.QUOTE_ASSET_SYMBOL);
    balanceStruct.balance -= int64(arguments.orderBookTrade.quoteQuantity) + buyFee;

    // Seller receives quote asset minus fees
    balanceStruct = loadBalanceStructAndMigrateIfNeeded(self, arguments.sell.wallet, Constants.QUOTE_ASSET_SYMBOL);
    balanceStruct.balance += int64(arguments.orderBookTrade.quoteQuantity) - sellFee;

    // Fee wallet receives maker and taker fees
    balanceStruct = loadBalanceStructAndMigrateIfNeeded(self, arguments.feeWallet, Constants.QUOTE_ASSET_SYMBOL);
    balanceStruct.balance += buyFee + sellFee;
  }

  // Withdrawing //

  function updateForWithdrawal(
    Storage storage self,
    Withdrawal memory withdrawal,
    address feeWallet
  ) internal returns (int64 newExchangeBalance) {
    Balance storage balanceStruct;

    balanceStruct = loadBalanceStructAndMigrateIfNeeded(self, withdrawal.wallet, Constants.QUOTE_ASSET_SYMBOL);
    // The calling function will subsequently validate this balance change by checking initial margin requirement
    balanceStruct.balance -= int64(withdrawal.grossQuantity);
    newExchangeBalance = balanceStruct.balance;

    if (withdrawal.gasFee > 0) {
      balanceStruct = loadBalanceStructAndMigrateIfNeeded(self, feeWallet, Constants.QUOTE_ASSET_SYMBOL);

      balanceStruct.balance += int64(withdrawal.gasFee);
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
    Balance memory balanceStruct = self.balancesByWalletAssetPair[wallet][assetSymbol];

    if (!balanceStruct.isMigrated && address(self.migrationSource) != address(0x0)) {
      balanceStruct = self.migrationSource.loadBalanceStructBySymbol(wallet, assetSymbol);
    }

    return balanceStruct;
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

    Balance memory migratedBalanceStruct;
    if (!balance.isMigrated && address(self.migrationSource) != address(0x0)) {
      migratedBalanceStruct = self.migrationSource.loadBalanceStructBySymbol(wallet, assetSymbol);
      migratedBalanceStruct.isMigrated = true;
      balance.balance = migratedBalanceStruct.balance;
      balance.lastUpdateTimestampInMs = migratedBalanceStruct.lastUpdateTimestampInMs;
      balance.costBasis = migratedBalanceStruct.costBasis;
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
    uint64 baseQuantity,
    address counterpartyWallet,
    bool isDeleverage,
    address liquidatingWallet,
    Market memory market,
    uint64 quoteQuantity,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    Balance storage balanceStruct;

    // Update liquidating wallet position by decreasing it towards zero
    balanceStruct = loadBalanceStructAndMigrateIfNeeded(self, liquidatingWallet, market.baseAssetSymbol);
    bool liquidatingWalletPositionIsShort = balanceStruct.balance < 0;
    if (liquidatingWalletPositionIsShort) {
      // Decrease negative short position by adding base quantity to it
      _validatePositionUpdatedTowardsZero(balanceStruct.balance, balanceStruct.balance + int64(baseQuantity));

      _addToPosition(
        balanceStruct,
        baseQuantity,
        quoteQuantity,
        market
          .loadMarketWithOverridesForWallet(liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maximumPositionSize
      );
    } else {
      // Decrease positive long position by subtracting base quantity from it
      _validatePositionUpdatedTowardsZero(balanceStruct.balance, balanceStruct.balance - int64(baseQuantity));

      _subtractFromPosition(
        balanceStruct,
        baseQuantity,
        quoteQuantity,
        market
          .loadMarketWithOverridesForWallet(liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maximumPositionSize
      );
    }
    // Update open position tracking in case any were closed
    _updateOpenPositionsForWallet(
      liquidatingWallet,
      market.baseAssetSymbol,
      balanceStruct.balance,
      baseAssetSymbolsWithOpenPositionsByWallet
    );
    balanceStruct = loadBalanceStructAndMigrateIfNeeded(self, liquidatingWallet, Constants.QUOTE_ASSET_SYMBOL);
    if (liquidatingWalletPositionIsShort) {
      // Liquidating wallet gives quote if short
      balanceStruct.balance -= int64(quoteQuantity);
    } else {
      // Liquidating wallet receives quote if long
      balanceStruct.balance += int64(quoteQuantity);
    }

    // Update counterparty wallet position by taking on liquidating wallet's position. During liquidation the IF or EF
    // the position may validly increase by moving away from zero, but this is disallowed for the counterparty wallet
    // position during deleveraging
    balanceStruct = loadBalanceStructAndMigrateIfNeeded(self, counterpartyWallet, market.baseAssetSymbol);

    if (liquidatingWalletPositionIsShort) {
      // Take on short position by subtracting base quantity
      if (isDeleverage) {
        _validatePositionUpdatedTowardsZero(balanceStruct.balance, balanceStruct.balance - int64(baseQuantity));
      }

      _subtractFromPosition(
        balanceStruct,
        baseQuantity,
        quoteQuantity,
        market
          .loadMarketWithOverridesForWallet(counterpartyWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maximumPositionSize
      );
    } else {
      // Take on long position by adding base quantity
      if (isDeleverage) {
        _validatePositionUpdatedTowardsZero(balanceStruct.balance, balanceStruct.balance + int64(baseQuantity));
      }

      _addToPosition(
        balanceStruct,
        baseQuantity,
        quoteQuantity,
        market
          .loadMarketWithOverridesForWallet(counterpartyWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maximumPositionSize
      );
    }
    // Update open position tracking in case any were opened (if counterparty wallet is IF or EF only) or closed
    _updateOpenPositionsForWallet(
      counterpartyWallet,
      market.baseAssetSymbol,
      balanceStruct.balance,
      baseAssetSymbolsWithOpenPositionsByWallet
    );
    // During liquidation, the IF or EF may open a position in a market for the first time. When this happens, the
    // position should be updated with the latest published funding rate for that market so that no funding is applied
    // retroactively
    if (balanceStruct.lastUpdateTimestampInMs == 0) {
      balanceStruct.lastUpdateTimestampInMs = lastFundingRatePublishTimestampInMsByBaseAssetSymbol[
        market.baseAssetSymbol
      ];
    }
    balanceStruct = loadBalanceStructAndMigrateIfNeeded(self, counterpartyWallet, Constants.QUOTE_ASSET_SYMBOL);
    if (liquidatingWalletPositionIsShort) {
      // Counterparty receives quote when taking on short position
      balanceStruct.balance += int64(quoteQuantity);
    } else {
      // Counterparty gives quote when taking on long position
      balanceStruct.balance -= int64(quoteQuantity);
    }
  }

  function _validatePositionUpdatedTowardsZero(int64 originalPositionSize, int64 newPositionSize) private pure {
    require(originalPositionSize != 0, "Position must be non-zero");

    bool isValidUpdate = originalPositionSize < 0
      ? newPositionSize > originalPositionSize && newPositionSize <= 0
      : newPositionSize < originalPositionSize && newPositionSize >= 0;
    require(isValidUpdate, "Position must move toward zero");
  }
}
