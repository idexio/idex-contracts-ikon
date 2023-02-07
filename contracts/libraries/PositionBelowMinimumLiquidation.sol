// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { Funding } from "./Funding.sol";
import { Math } from "./Math.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Margin } from "./Margin.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { FundingMultiplierQuartet, IndexPrice, Market, MarketOverrides, PositionBelowMinimumLiquidationArguments } from "./Structs.sol";

library PositionBelowMinimumLiquidation {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
  using SortedStringSet for string[];

  uint64 private constant _MINIMUM_QUOTE_QUANTITY_VALIDATION_THRESHOLD = 10000;

  /**
   * @dev Argument for `liquidate`
   */
  struct Arguments {
    PositionBelowMinimumLiquidationArguments externalArguments;
    // Exchange state
    uint64 positionBelowMinimumLiquidationPriceToleranceMultiplier;
    address insuranceFundWallet;
  }

  // solhint-disable-next-line func-name-mixedcase
  function liquidate_delegatecall(
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    Funding.updateWalletFunding(
      arguments.externalArguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.updateWalletFunding(
      arguments.insuranceFundWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) = Margin
      .loadTotalAccountValueAndMaintenanceMarginRequirement(
        arguments.externalArguments.liquidatingWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    require(totalAccountValue >= int64(totalMaintenanceMarginRequirement), "Maintenance margin requirement not met");

    _validateAndLiquidatePositionBelowMinimum(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _loadAndValidateMarketAndIndexPrice(
    Arguments memory arguments,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (Market memory market) {
    market = marketsByBaseAssetSymbol[arguments.externalArguments.baseAssetSymbol];
    require(market.exists && market.isActive, "No active market found");

    uint256 i = baseAssetSymbolsWithOpenPositionsByWallet[arguments.externalArguments.liquidatingWallet].indexOf(
      arguments.externalArguments.baseAssetSymbol
    );
    require(i != SortedStringSet.NOT_FOUND, "Open position not found for market");
  }

  function _updateBalances(
    Arguments memory arguments,
    Market memory market,
    int64 positionSize,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    balanceTracking.updatePositionForLiquidation(
      arguments.insuranceFundWallet,
      arguments.externalArguments.liquidatingWallet,
      market,
      positionSize,
      arguments.externalArguments.liquidationQuoteQuantity,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function _validateAndLiquidatePositionBelowMinimum(
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    Market memory market = _loadAndValidateMarketAndIndexPrice(
      arguments,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    // Validate that position is under dust threshold
    int64 positionSize = balanceTracking.loadBalanceAndMigrateIfNeeded(
      arguments.externalArguments.liquidatingWallet,
      arguments.externalArguments.baseAssetSymbol
    );
    require(
      Math.abs(positionSize) <
        market
          .loadMarketWithOverridesForWallet(
            arguments.externalArguments.liquidatingWallet,
            marketOverridesByBaseAssetSymbolAndWallet
          )
          .overridableFields
          .minimumPositionSize,
      "Position size above minimum"
    );

    // Validate quote quantity
    _validateQuoteQuantity(
      arguments.positionBelowMinimumLiquidationPriceToleranceMultiplier,
      arguments.externalArguments.liquidationQuoteQuantity,
      market.lastIndexPrice,
      positionSize
    );

    // Need to wrap `balanceTracking.updatePositionForLiquidation` with helper to avoid stack too deep error
    _updateBalances(
      arguments,
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
    if (expectedLiquidationQuoteQuantity < _MINIMUM_QUOTE_QUANTITY_VALIDATION_THRESHOLD) {
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
