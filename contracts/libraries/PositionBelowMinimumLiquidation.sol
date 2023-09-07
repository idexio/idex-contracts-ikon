// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { Funding } from "./Funding.sol";
import { IndexPriceMargin } from "./IndexPriceMargin.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Math } from "./Math.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { FundingMultiplierQuartet, Market, MarketOverrides, PositionBelowMinimumLiquidationArguments } from "./Structs.sol";

library PositionBelowMinimumLiquidation {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
  using SortedStringSet for string[];

  /**
   * @notice Emitted when the Dispatcher Wallet submits a position below minimum liquidation with
   * `liquidatePositionBelowMinimum`
   */
  event LiquidatedPositionBelowMinimum(
    string baseAssetSymbol,
    address liquidatingWallet,
    uint64 liquidationBaseQuantity,
    uint64 liquidationQuoteQuantity
  );

  // solhint-disable-next-line func-name-mixedcase
  function liquidate_delegatecall(
    PositionBelowMinimumLiquidationArguments memory arguments,
    address exitFundWallet,
    address insuranceFundWallet,
    uint64 positionBelowMinimumLiquidationPriceToleranceMultiplier,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    require(arguments.liquidatingWallet != exitFundWallet, "Cannot liquidate EF");
    require(arguments.liquidatingWallet != insuranceFundWallet, "Cannot liquidate IF");

    Funding.applyOutstandingWalletFunding(
      arguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.applyOutstandingWalletFunding(
      insuranceFundWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    uint64 liquidationBaseQuantity = _validateAndLiquidatePositionBelowMinimum(
      arguments,
      exitFundWallet,
      insuranceFundWallet,
      positionBelowMinimumLiquidationPriceToleranceMultiplier,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    // Validate that the Insurance Fund still meets its initial margin requirements
    IndexPriceMargin.validateInitialMarginRequirement(
      insuranceFundWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    _emitLiquidatedPositionBelowMinimum(arguments, liquidationBaseQuantity);
  }

  function _emitLiquidatedPositionBelowMinimum(
    PositionBelowMinimumLiquidationArguments memory arguments,
    uint64 liquidationBaseQuantity
  ) private {
    emit LiquidatedPositionBelowMinimum(
      arguments.baseAssetSymbol,
      arguments.liquidatingWallet,
      liquidationBaseQuantity,
      arguments.liquidationQuoteQuantity
    );
  }

  function _updateBalances(
    PositionBelowMinimumLiquidationArguments memory arguments,
    address exitFundWallet,
    address insuranceFundWallet,
    Market memory market,
    int64 positionSize,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    balanceTracking.updatePositionsForLiquidation(
      insuranceFundWallet,
      exitFundWallet,
      arguments.liquidatingWallet,
      market,
      positionSize,
      arguments.liquidationQuoteQuantity,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function _validateAndLiquidatePositionBelowMinimum(
    PositionBelowMinimumLiquidationArguments memory arguments,
    address exitFundWallet,
    address insuranceFundWallet,
    uint64 positionBelowMinimumLiquidationPriceToleranceMultiplier,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private returns (uint64 liquidationBaseQuantity) {
    Market memory market = Validations.loadAndValidateActiveMarket(
      arguments.baseAssetSymbol,
      arguments.liquidatingWallet,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    // Validate that position is under dust threshold
    int64 positionSize = balanceTracking.loadBalanceAndMigrateIfNeeded(
      arguments.liquidatingWallet,
      arguments.baseAssetSymbol
    );
    require(
      Math.abs(positionSize) <
        market
          .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .minimumPositionSize,
      "Position size above minimum"
    );
    liquidationBaseQuantity = Math.abs(positionSize);

    // Validate quote quantity
    _validateQuoteQuantity(
      positionBelowMinimumLiquidationPriceToleranceMultiplier,
      arguments.liquidationQuoteQuantity,
      market.lastIndexPrice,
      positionSize
    );

    // Need to wrap `balanceTracking.updatePositionForLiquidation` with helper to avoid stack too deep error
    _updateBalances(
      arguments,
      exitFundWallet,
      insuranceFundWallet,
      market,
      positionSize,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function _validateQuoteQuantity(
    uint64 positionBelowMinimumLiquidationPriceTolerance,
    uint64 liquidationQuoteQuantity,
    uint64 indexPrice,
    int64 positionSize
  ) private pure {
    uint64 expectedLiquidationQuoteQuantity = Math.multiplyPipsByFraction(
      Math.abs(positionSize),
      indexPrice,
      Constants.PIP_PRICE_MULTIPLIER
    );

    // Skip validation for positions with very low quote values to avoid false positives due to rounding error
    if (
      expectedLiquidationQuoteQuantity < Constants.MINIMUM_QUOTE_QUANTITY_VALIDATION_THRESHOLD &&
      liquidationQuoteQuantity < Constants.MINIMUM_QUOTE_QUANTITY_VALIDATION_THRESHOLD
    ) {
      return;
    }

    uint64 tolerance = Math.multiplyPipsByFraction(
      positionBelowMinimumLiquidationPriceTolerance,
      expectedLiquidationQuoteQuantity,
      Constants.PIP_PRICE_MULTIPLIER
    );

    require(
      expectedLiquidationQuoteQuantity - tolerance <= liquidationQuoteQuantity &&
        expectedLiquidationQuoteQuantity + tolerance >= liquidationQuoteQuantity,
      "Invalid quote quantity"
    );
  }
}
