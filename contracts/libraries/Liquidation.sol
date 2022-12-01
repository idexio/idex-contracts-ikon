// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { ExitFund } from "./ExitFund.sol";
import { Funding } from "./Funding.sol";
import { LiquidationType } from "./Enums.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { Margin } from "./Margin.sol";
import { Math } from "./Math.sol";
import { MarketOverrides } from "./MarketOverrides.sol";
import { String } from "./String.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { Balance, FundingMultiplierQuartet, Market, IndexPrice } from "./Structs.sol";

library Liquidation {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketOverrides for Market;
  using SortedStringSet for string[];

  /**
   * @dev Argument for `liquidatePositionBelowMinimum`
   */
  struct LiquidatePositionBelowMinimumArguments {
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

  /**
   * @dev Argument for `liquidatePositionInDeactivatedMarket`
   */
  struct LiquidatePositionInDeactivatedMarketArguments {
    // External arguments
    string baseAssetSymbol;
    address liquidatingWallet;
    int64 liquidationQuoteQuantityInPips; // For the position being liquidated
    IndexPrice[] liquidatingWalletIndexPrices; // Before liquidation
    // Exchange state
    address[] indexPriceCollectionServiceWallets;
  }

  /**
   * @dev Argument for `liquidateWallet`
   */
  struct LiquidateWalletArguments {
    // External arguments
    LiquidationType liquidationType;
    address counterpartyWallet; // Insurance Fund or Exit Fund
    IndexPrice[] counterpartyWalletIndexPrices; // After acquiring liquidated positions
    address liquidatingWallet;
    IndexPrice[] liquidatingWalletIndexPrices;
    int64[] liquidationQuoteQuantitiesInPips;
    // Exchange state
    address[] indexPriceCollectionServiceWallets;
  }

  function liquidatePositionBelowMinimum(
    Liquidation.LiquidatePositionBelowMinimumArguments memory arguments,
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

    _liquidatePositionBelowMinimum(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _liquidatePositionBelowMinimum(
    LiquidatePositionBelowMinimumArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
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

  function liquidatePositionInDeactivatedMarket(
    Liquidation.LiquidatePositionInDeactivatedMarketArguments memory arguments,
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

    _liquidatePositionInDeactivatedMarket(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _liquidatePositionInDeactivatedMarket(
    LiquidatePositionInDeactivatedMarketArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
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

    _validateQuantitiesAndLiquidatePositionInDeactivatedMarket(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );
  }

  function liquidateWallet(
    Liquidation.LiquidateWalletArguments memory arguments,
    uint256 exitFundPositionOpenedAtBlockNumber,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public returns (uint256) {
    Funding.updateWalletFundingInternal(
      arguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.updateWalletFundingInternal(
      arguments.counterpartyWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    _liquidateWallet(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    if (arguments.liquidationType == LiquidationType.WalletInMaintenanceDuringSystemRecovery) {
      return
        ExitFund.getExitFundBalanceOpenedAtBlockNumber(
          arguments.liquidatingWallet,
          exitFundPositionOpenedAtBlockNumber,
          balanceTracking,
          baseAssetSymbolsWithOpenPositionsByWallet
        );
    }

    return exitFundPositionOpenedAtBlockNumber;
  }

  function _liquidateWallet(
    LiquidateWalletArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    // FIXME Do not allow liquidation of insurance or exit funds

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
    if (
      arguments.liquidationType == LiquidationType.WalletInMaintenance ||
      arguments.liquidationType == LiquidationType.WalletInMaintenanceDuringSystemRecovery
    ) {
      require(
        totalAccountValueInPips < int64(totalMaintenanceMarginRequirementInPips),
        "Maintenance margin requirement met"
      );
    }

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet];
    for (uint8 index = 0; index < baseAssetSymbols.length; index++) {
      _validateQuoteQuantityAndLiquidatePosition(
        index,
        arguments,
        marketsByBaseAssetSymbol[baseAssetSymbols[index]],
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet
      );
    }

    balanceTracking.updateQuoteForLiquidation(arguments.counterpartyWallet, arguments.liquidatingWallet);

    if (
      arguments.liquidationType == LiquidationType.WalletExited ||
      arguments.liquidationType == LiquidationType.WalletInMaintenance
    ) {
      // Validate that the Insurance Fund still meets its initial margin requirements
      Margin.loadAndValidateTotalAccountValueAndInitialMarginRequirement(
        Margin.LoadArguments(
          arguments.counterpartyWallet,
          arguments.counterpartyWalletIndexPrices,
          arguments.indexPriceCollectionServiceWallets
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    }
  }

  function _validateQuantitiesAndLiquidatePositionBelowMinimum(
    LiquidatePositionBelowMinimumArguments memory arguments,
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
    LiquidationValidations.validatePositionBelowMinimumLiquidationQuoteQuantity(
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

  function _validateQuantitiesAndLiquidatePositionInDeactivatedMarket(
    LiquidatePositionInDeactivatedMarketArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    Market memory market = _loadMarket(arguments, baseAssetSymbolsWithOpenPositionsByWallet, marketsByBaseAssetSymbol);

    // Validate quote quantity
    LiquidationValidations.validateDeactivatedMarketLiquidationQuoteQuantity(
      market.indexPriceInPipsAtDeactivation,
      balanceTracking.loadBalanceFromMigrationSourceIfNeeded(arguments.liquidatingWallet, market.baseAssetSymbol),
      arguments.liquidationQuoteQuantityInPips
    );

    balanceTracking.updatePositionForDeactivatedMarketLiquidation(
      market.baseAssetSymbol,
      arguments.liquidatingWallet,
      arguments.liquidationQuoteQuantityInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
    );
  }

  function _validateQuoteQuantityAndLiquidatePosition(
    uint8 index,
    LiquidateWalletArguments memory arguments,
    Market memory market,
    int64 totalAccountValueInPips,
    uint64 totalMaintenanceMarginRequirementInPips,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    Balance storage balance = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.liquidatingWallet,
      market.baseAssetSymbol
    );
    Validations.validateIndexPrice(
      arguments.liquidatingWalletIndexPrices[index],
      market,
      arguments.indexPriceCollectionServiceWallets
    );

    if (
      arguments.liquidationType == LiquidationType.WalletInMaintenance ||
      arguments.liquidationType == LiquidationType.WalletInMaintenanceDuringSystemRecovery
    ) {
      LiquidationValidations.validateLiquidationQuoteQuantityToClosePositions(
        arguments.liquidationQuoteQuantitiesInPips[index],
        market
          .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .maintenanceMarginFractionInPips,
        arguments.liquidatingWalletIndexPrices[index].price,
        balance.balanceInPips,
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips
      );
    } else {
      // LiquidationType.WalletExited
      LiquidationValidations.validateExitQuoteQuantity(
        balance.costBasisInPips,
        arguments.liquidationQuoteQuantitiesInPips[index],
        arguments.liquidatingWalletIndexPrices[index].price,
        balance.balanceInPips,
        totalAccountValueInPips
      );
    }

    balanceTracking.updatePositionForLiquidation(
      balance.balanceInPips,
      arguments.counterpartyWallet,
      arguments.liquidatingWallet,
      market,
      arguments.liquidationQuoteQuantitiesInPips[index],
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function _loadMarket(
    LiquidatePositionInDeactivatedMarketArguments memory arguments,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (Market memory market) {
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      if (String.isEqual(baseAssetSymbols[i], arguments.baseAssetSymbol)) {
        market = marketsByBaseAssetSymbol[arguments.baseAssetSymbol];
      }
    }

    require(market.exists && !market.isActive, "No inactive market found");
  }

  function _loadMarketAndIndexPrice(
    LiquidatePositionBelowMinimumArguments memory arguments,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (Market memory market, IndexPrice memory indexPrice) {
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      if (String.isEqual(baseAssetSymbols[i], arguments.baseAssetSymbol)) {
        market = marketsByBaseAssetSymbol[arguments.baseAssetSymbol];
        indexPrice = arguments.liquidatingWalletIndexPrices[i];
      }
    }

    require(market.exists && market.isActive, "No active market found");
  }
}
