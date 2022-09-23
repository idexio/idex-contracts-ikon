// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { LiquidationType } from './Enums.sol';
import { LiquidationValidations } from './LiquidationValidations.sol';
import { Margin } from './Margin.sol';
import { Math } from './Math.sol';
import { MarketOverrides } from './MarketOverrides.sol';
import { String } from './String.sol';
import { SortedStringSet } from './SortedStringSet.sol';
import { Validations } from './Validations.sol';
import { Balance, Market, OraclePrice } from './Structs.sol';

library Liquidation {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketOverrides for Market;
  using SortedStringSet for string[];

  /**
   * @dev Argument for `liquidateDustPosition`
   */
  struct LiquidateDustPositionArguments {
    // External arguments
    string baseAssetSymbol;
    address liquidatingWallet;
    int64 liquidationQuoteQuantityInPips; // For the position being liquidated
    OraclePrice[] insuranceFundOraclePrices; // After acquiring liquidating position
    OraclePrice[] liquidatingWalletOraclePrices; // Before liquidation
    // Exchange state
    uint64 dustPositionLiquidationPriceToleranceBasisPoints;
    address insuranceFundWallet;
    address oracleWallet;
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
  }

  /**
   * @dev Argument for `liquidateInactiveMarketPosition`
   */
  struct LiquidateInactiveMarketPositionArguments {
    // External arguments
    string baseAssetSymbol;
    address liquidatingWallet;
    int64 liquidationQuoteQuantityInPips; // For the position being liquidated
    OraclePrice[] liquidatingWalletOraclePrices; // Before liquidation
    // Exchange state
    address oracleWallet;
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
  }

  /**
   * @dev Argument for `liquidateWallet`
   */
  struct LiquidateWalletArguments {
    // External arguments
    LiquidationType liquidationType;
    address counterpartyWallet; // Insurance Fund or Exit Fund
    OraclePrice[] counterpartyWalletOraclePrices; // After acquiring liquidated positions
    address liquidatingWallet;
    OraclePrice[] liquidatingWalletOraclePrices;
    int64[] liquidationQuoteQuantitiesInPips;
    // Exchange state
    address oracleWallet;
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
  }

  function liquidateDustPosition(
    LiquidateDustPositionArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal {
    (
      int64 totalAccountValueInPips,
      uint64 totalMaintenanceMarginRequirementInPips
    ) = Margin.loadTotalAccountValueAndMaintenanceMarginRequirement(
        Margin.LoadArguments(
          arguments.liquidatingWallet,
          arguments.liquidatingWalletOraclePrices,
          arguments.oracleWallet,
          arguments.quoteAssetDecimals,
          arguments.quoteAssetSymbol
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    require(
      totalAccountValueInPips >= int64(totalMaintenanceMarginRequirementInPips),
      'Maintenance margin requirement not met'
    );

    validateQuantitiesAndLiquidateDustPosition(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function liquidateInactiveMarketPosition(
    LiquidateInactiveMarketPositionArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal {
    (
      int64 totalAccountValueInPips,
      uint64 totalMaintenanceMarginRequirementInPips
    ) = Margin.loadTotalAccountValueAndMaintenanceMarginRequirement(
        Margin.LoadArguments(
          arguments.liquidatingWallet,
          arguments.liquidatingWalletOraclePrices,
          arguments.oracleWallet,
          arguments.quoteAssetDecimals,
          arguments.quoteAssetSymbol
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    require(
      totalAccountValueInPips >= int64(totalMaintenanceMarginRequirementInPips),
      'Maintenance margin requirement not met'
    );

    validateQuantitiesAndLiquidateInactiveMarketPosition(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );
  }

  function liquidateWallet(
    LiquidateWalletArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal {
    // FIXME Do not allow liquidation of insurance or exit funds

    (
      int64 totalAccountValueInPips,
      uint64 totalMaintenanceMarginRequirementInPips
    ) = Margin.loadTotalAccountValueAndMaintenanceMarginRequirement(
        Margin.LoadArguments(
          arguments.liquidatingWallet,
          arguments.liquidatingWalletOraclePrices,
          arguments.oracleWallet,
          arguments.quoteAssetDecimals,
          arguments.quoteAssetSymbol
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    if (
      arguments.liquidationType == LiquidationType.InMaintenanceWallet ||
      arguments.liquidationType ==
      LiquidationType.InMaintenanceWalletDuringSystemRecovery
    ) {
      require(
        totalAccountValueInPips <
          int64(totalMaintenanceMarginRequirementInPips),
        'Maintenance margin requirement met'
      );
    }

    string[]
      memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
        arguments.liquidatingWallet
      ];
    for (uint8 index = 0; index < baseAssetSymbols.length; index++) {
      validateQuoteQuantityAndLiquidatePosition(
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

    balanceTracking.updateQuoteForLiquidation(
      arguments.quoteAssetSymbol,
      arguments.counterpartyWallet,
      arguments.liquidatingWallet
    );

    if (
      arguments.liquidationType == LiquidationType.ExitedWallet ||
      arguments.liquidationType == LiquidationType.InMaintenanceWallet
    ) {
      // Validate that the Insurance Fund still meets its initial margin requirements
      Margin.loadAndValidateTotalAccountValueAndInitialMarginRequirement(
        Margin.LoadArguments(
          arguments.counterpartyWallet,
          arguments.counterpartyWalletOraclePrices,
          arguments.oracleWallet,
          arguments.quoteAssetDecimals,
          arguments.quoteAssetSymbol
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    }
  }

  function validateQuantitiesAndLiquidateDustPosition(
    LiquidateDustPositionArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    (
      Market memory market,
      OraclePrice memory oraclePrice
    ) = loadMarketAndOraclePrice(
        arguments,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      );

    // Validate that position is under dust threshold
    int64 positionSizeInPips = balanceTracking
      .loadBalanceInPipsFromMigrationSourceIfNeeded(
        arguments.liquidatingWallet,
        arguments.baseAssetSymbol
      );
    require(
      Math.abs(positionSizeInPips) <
        market
          .loadMarketWithOverridesForWallet(
            arguments.liquidatingWallet,
            marketOverridesByBaseAssetSymbolAndWallet
          )
          .minimumPositionSizeInPips,
      'Position size above minimum'
    );

    // Validate quote quantity
    uint64 oraclePriceInPips = Validations.validateOraclePriceAndConvertToPips(
      oraclePrice,
      arguments.quoteAssetDecimals,
      market,
      arguments.oracleWallet
    );
    LiquidationValidations.validateDustLiquidationQuoteQuantity(
      arguments.dustPositionLiquidationPriceToleranceBasisPoints,
      arguments.liquidationQuoteQuantityInPips,
      oraclePriceInPips,
      positionSizeInPips
    );

    balanceTracking.updatePositionForLiquidation(
      positionSizeInPips,
      arguments.insuranceFundWallet,
      arguments.liquidatingWallet,
      market,
      arguments.quoteAssetSymbol,
      arguments.liquidationQuoteQuantityInPips,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function validateQuantitiesAndLiquidateInactiveMarketPosition(
    LiquidateInactiveMarketPositionArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    Market memory market = loadMarket(
      arguments,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    // Validate quote quantity
    LiquidationValidations.validateInactiveMarketLiquidationQuoteQuantity(
      market.oraclePriceInPipsAtDeactivation,
      balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
        arguments.liquidatingWallet,
        market.baseAssetSymbol
      ),
      arguments.liquidationQuoteQuantityInPips
    );

    balanceTracking.updatePositionForInactiveMarketLiquidation(
      market.baseAssetSymbol,
      arguments.liquidatingWallet,
      arguments.quoteAssetSymbol,
      arguments.liquidationQuoteQuantityInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
    );
  }

  function validateQuoteQuantityAndLiquidatePosition(
    uint8 index,
    LiquidateWalletArguments memory arguments,
    Market memory market,
    int64 totalAccountValueInPips,
    uint64 totalMaintenanceMarginRequirementInPips,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    Balance storage balance = balanceTracking.loadBalanceAndMigrateIfNeeded(
      arguments.liquidatingWallet,
      market.baseAssetSymbol
    );
    uint64 oraclePriceInPips = Validations.validateOraclePriceAndConvertToPips(
      arguments.liquidatingWalletOraclePrices[index],
      arguments.quoteAssetDecimals,
      market,
      arguments.oracleWallet
    );

    if (
      arguments.liquidationType == LiquidationType.InMaintenanceWallet ||
      arguments.liquidationType ==
      LiquidationType.InMaintenanceWalletDuringSystemRecovery
    ) {
      LiquidationValidations.validateLiquidationQuoteQuantity(
        arguments.liquidationQuoteQuantitiesInPips[index],
        market
          .loadMarketWithOverridesForWallet(
            arguments.liquidatingWallet,
            marketOverridesByBaseAssetSymbolAndWallet
          )
          .maintenanceMarginFractionInPips,
        oraclePriceInPips,
        balance.balanceInPips,
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips
      );
    } else {
      // LiquidationType.Exit
      LiquidationValidations.validateExitQuoteQuantity(
        balance.costBasisInPips,
        arguments.liquidationQuoteQuantitiesInPips[index],
        market
          .loadMarketWithOverridesForWallet(
            arguments.liquidatingWallet,
            marketOverridesByBaseAssetSymbolAndWallet
          )
          .maintenanceMarginFractionInPips,
        oraclePriceInPips,
        balance.balanceInPips,
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips
      );
    }

    balanceTracking.updatePositionForLiquidation(
      balance.balanceInPips,
      arguments.counterpartyWallet,
      arguments.liquidatingWallet,
      market,
      arguments.quoteAssetSymbol,
      arguments.liquidationQuoteQuantitiesInPips[index],
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function loadMarket(
    LiquidateInactiveMarketPositionArguments memory arguments,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (Market memory market) {
    string[]
      memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
        arguments.liquidatingWallet
      ];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      if (String.isEqual(baseAssetSymbols[i], arguments.baseAssetSymbol)) {
        market = marketsByBaseAssetSymbol[arguments.baseAssetSymbol];
      }
    }

    require(market.exists && !market.isActive, 'No inactive market found');
  }

  function loadMarketAndOraclePrice(
    LiquidateDustPositionArguments memory arguments,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  )
    private
    view
    returns (Market memory market, OraclePrice memory oraclePrice)
  {
    string[]
      memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
        arguments.liquidatingWallet
      ];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      if (String.isEqual(baseAssetSymbols[i], arguments.baseAssetSymbol)) {
        market = marketsByBaseAssetSymbol[arguments.baseAssetSymbol];
        oraclePrice = arguments.liquidatingWalletOraclePrices[i];
      }
    }

    require(market.exists && market.isActive, 'No active market found');
  }
}
