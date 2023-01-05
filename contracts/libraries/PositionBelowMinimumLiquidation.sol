// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { Funding } from "./Funding.sol";
import { Math } from "./Math.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { MutatingMargin } from "./MutatingMargin.sol";
import { NonMutatingMargin } from "./NonMutatingMargin.sol";
import { String } from "./String.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { FundingMultiplierQuartet, IndexPrice, Market, MarketOverrides } from "./Structs.sol";

library PositionBelowMinimumLiquidation {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
  using SortedStringSet for string[];

  /**
   * @dev Argument for `liquidate`
   */
  struct Arguments {
    // External arguments
    string baseAssetSymbol;
    address liquidatingWallet;
    uint64 liquidationQuoteQuantity; // For the position being liquidated
    IndexPrice[] insuranceFundIndexPrices; // After acquiring liquidating position
    IndexPrice[] liquidatingWalletIndexPrices; // Before liquidation
    // Exchange state
    uint64 dustPositionLiquidationPriceTolerance;
    address insuranceFundWallet;
    address[] indexPriceCollectionServiceWallets;
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
      arguments.liquidatingWallet,
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

    (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) = MutatingMargin
      .loadTotalAccountValueAndMaintenanceMarginRequirementAndUpdateLastIndexPrice(
        NonMutatingMargin.LoadArguments(
          arguments.liquidatingWallet,
          arguments.liquidatingWalletIndexPrices,
          arguments.indexPriceCollectionServiceWallets
        ),
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

  function _loadMarketAndIndexPrice(
    Arguments memory arguments,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (Market memory market, IndexPrice memory indexPrice) {
    market = marketsByBaseAssetSymbol[arguments.baseAssetSymbol];
    require(market.exists && market.isActive, "No active market found");

    uint256 i = baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet].indexOf(
      arguments.baseAssetSymbol
    );
    require(i != SortedStringSet.NOT_FOUND, "Index price not found for market");

    indexPrice = arguments.liquidatingWalletIndexPrices[i];
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
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    (Market memory market, IndexPrice memory indexPrice) = _loadMarketAndIndexPrice(
      arguments,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );
    Validations.validateIndexPrice(indexPrice, arguments.indexPriceCollectionServiceWallets, market);

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
      arguments.dustPositionLiquidationPriceTolerance,
      arguments.liquidationQuoteQuantity,
      indexPrice.price,
      positionSize
    );

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
    uint64 expectedLiquidationQuoteQuantities = Math.multiplyPipsByFraction(
      Math.abs(positionSize),
      indexPrice,
      Constants.PIP_PRICE_MULTIPLIER
    );
    uint64 tolerance = (positionBelowMinimumLiquidationPriceTolerance * expectedLiquidationQuoteQuantities) /
      Constants.PIP_PRICE_MULTIPLIER;

    require(
      expectedLiquidationQuoteQuantities - tolerance <= liquidationQuoteQuantity &&
        expectedLiquidationQuoteQuantities + tolerance >= liquidationQuoteQuantity,
      "Invalid liquidation quote quantity"
    );
  }
}
