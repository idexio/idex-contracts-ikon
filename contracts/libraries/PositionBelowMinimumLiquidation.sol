// SPDX-License-Identifier: LGPL-3.0-only

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
    Funding.updateWalletFunding(
      arguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.updateWalletFunding(
      insuranceFundWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) = IndexPriceMargin
      .loadTotalAccountValueAndMaintenanceMarginRequirement(
        arguments.liquidatingWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    require(totalAccountValue >= int64(totalMaintenanceMarginRequirement), "Maintenance margin requirement not met");

    _validateAndLiquidatePositionBelowMinimum(
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
    IndexPriceMargin.loadAndValidateTotalAccountValueAndInitialMarginRequirement(
      insuranceFundWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
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
    balanceTracking.updatePositionForLiquidation(
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
  ) private {
    Market memory market = Validations.loadAndValidateMarket(
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
    if (expectedLiquidationQuoteQuantity < Constants.MINIMUM_QUOTE_QUANTITY_VALIDATION_THRESHOLD) {
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
      "Invalid liquidation quote quantity"
    );
  }
}
