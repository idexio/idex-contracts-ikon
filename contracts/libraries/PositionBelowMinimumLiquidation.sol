// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { Funding } from "./Funding.sol";
import { Math } from "./Math.sol";
import { FundingMultiplierQuartet, IndexPrice } from "./Structs.sol";
import { Margin, Market } from "./Margin.sol";
import { MarketOverrides } from "./MarketOverrides.sol";
import { String } from "./String.sol";
import { Validations } from "./Validations.sol";

library PositionBelowMinimumLiquidation {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketOverrides for Market;

  /**
   * @dev Argument for `liquidate`
   */
  struct Arguments {
    // External arguments
    string baseAssetSymbol;
    address liquidatingWallet;
    int64 liquidationQuoteQuantityInPips; // For the position being liquidated
    IndexPrice[] insuranceFundIndexPrices; // After acquiring liquidating position
    IndexPrice[] liquidatingWalletIndexPrices; // Before liquidation
    // Exchange state
    uint64 dustPositionLiquidationPriceTolerance;
    address insuranceFundWallet;
    address[] indexPriceCollectionServiceWallets;
  }

  function liquidate(
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    Funding.updateWalletFundingInternal(
      arguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.updateWalletFundingInternal(
      arguments.insuranceFundWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    (int64 totalAccountValueInPips, uint64 totalMaintenanceMarginRequirementInPips) = Margin
      .loadTotalAccountValueAndMaintenanceMarginRequirement(
        Margin.LoadArguments(
          arguments.liquidatingWallet,
          arguments.liquidatingWalletIndexPrices,
          arguments.indexPriceCollectionServiceWallets
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    require(
      totalAccountValueInPips >= int64(totalMaintenanceMarginRequirementInPips),
      "Maintenance margin requirement not met"
    );

    _validateQuantitiesAndLiquidatePositionBelowMinimum(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _loadMarketAndIndexPrice(
    Arguments memory arguments,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (Market memory market, IndexPrice memory indexPrice) {
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      if (String.isEqual(baseAssetSymbols[i], arguments.baseAssetSymbol)) {
        market = marketsByBaseAssetSymbol[arguments.baseAssetSymbol];
        indexPrice = arguments.liquidatingWalletIndexPrices[i];
        break;
      }
    }

    require(market.exists && market.isActive, "No active market found");
  }

  function _validatePositionBelowMinimumLiquidationQuoteQuantity(
    uint64 positionBelowMinimumLiquidationPriceTolerance,
    int64 liquidationQuoteQuantity,
    uint64 indexPrice,
    int64 positionSize
  ) private pure {
    int64 expectedLiquidationQuoteQuantities = Math.multiplyPipsByFraction(
      positionSize,
      int64(indexPrice),
      int64(Constants.PIP_PRICE_MULTIPLIER)
    );
    uint64 tolerance = (positionBelowMinimumLiquidationPriceTolerance * Math.abs(expectedLiquidationQuoteQuantities)) /
      Constants.PIP_PRICE_MULTIPLIER;

    require(
      expectedLiquidationQuoteQuantities - int64(tolerance) <= liquidationQuoteQuantity &&
        expectedLiquidationQuoteQuantities + int64(tolerance) >= liquidationQuoteQuantity,
      "Invalid liquidation quote quantity"
    );
  }

  function _validateQuantitiesAndLiquidatePositionBelowMinimum(
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    (Market memory market, IndexPrice memory indexPrice) = _loadMarketAndIndexPrice(
      arguments,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    // Validate that position is under dust threshold
    int64 positionSizeInPips = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
      arguments.liquidatingWallet,
      arguments.baseAssetSymbol
    );
    require(
      Math.abs(positionSizeInPips) <
        market
          .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .minimumPositionSizeInPips,
      "Position size above minimum"
    );

    // Validate quote quantity
    Validations.validateIndexPrice(indexPrice, market, arguments.indexPriceCollectionServiceWallets);
    _validatePositionBelowMinimumLiquidationQuoteQuantity(
      arguments.dustPositionLiquidationPriceTolerance,
      arguments.liquidationQuoteQuantityInPips,
      indexPrice.price,
      positionSizeInPips
    );

    balanceTracking.updatePositionForLiquidation(
      positionSizeInPips,
      arguments.insuranceFundWallet,
      arguments.liquidatingWallet,
      market,
      arguments.liquidationQuoteQuantityInPips,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }
}
