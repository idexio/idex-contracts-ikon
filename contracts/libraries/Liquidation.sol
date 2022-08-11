// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.15;

import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { LiquidationValidations } from './LiquidationValidations.sol';
import { Margin } from './Margin.sol';
import { Validations } from './Validations.sol';
import { Balance, Market, OraclePrice } from './Structs.sol';

library Liquidation {
  using BalanceTracking for BalanceTracking.Storage;

  struct DeleverageArguments {
    // External arguments
    string baseAssetSymbol;
    address deleveragingWallet;
    address liquidatingWallet;
    int64 liquidationQuoteQuantityInPips;
    OraclePrice[] oraclePrices;
    // Exchange state
    uint8 collateralAssetDecimals;
    string collateralAssetSymbol;
    address insuranceFundWalletAddress;
    address oracleWalletAddress;
  }

  struct LiquidateArguments {
    // External arguments
    address wallet;
    int64[] liquidationQuoteQuantitiesInPips;
    OraclePrice[] oraclePrices;
    // Exchange state
    uint8 collateralAssetDecimals;
    string collateralAssetSymbol;
    address insuranceFundWalletAddress;
    address oracleWalletAddress;
  }

  function liquidate(
    LiquidateArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal {
    // FIXME Do not allow liquidation of insurance or exit funds

    (
      int64 totalAccountValueInPips,
      uint64 totalMaintenanceMarginRequirementInPips
    ) = loadTotalAccountValueAndMarginRequirement(
        arguments,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
      );

    require(
      totalAccountValueInPips <= int64(totalMaintenanceMarginRequirementInPips),
      'Maintenance margin met'
    );

    string[] memory marketSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
      arguments.wallet
    ];
    for (uint8 i = 0; i < marketSymbols.length; i++) {
      // FIXME Insurance fund margin requirements
      liquidateMarket(
        arguments,
        marketsByBaseAssetSymbol[marketSymbols[i]],
        arguments.liquidationQuoteQuantitiesInPips[i],
        arguments.oraclePrices[i],
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet
      );
    }
  }

  function liquidationAcquisitionDeleverage(
    DeleverageArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal {
    (
      int64 totalAccountValueInPips,
      uint64 totalMaintenanceMarginRequirementInPips
    ) = loadTotalAccountValueAndMarginRequirement(
        arguments,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
      );

    require(
      totalAccountValueInPips <= int64(totalMaintenanceMarginRequirementInPips),
      'Maintenance margin met'
    );
  }

  function liquidateMarket(
    LiquidateArguments memory arguments,
    Market memory market,
    int64 liquidationQuoteQuantitiesInPips,
    OraclePrice memory oraclePrice,
    int64 totalAccountValueInPips,
    uint64 totalMaintenanceMarginRequirementInPips,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet
  ) private {
    int64 positionSizeInPips = balanceTracking
      .loadBalanceAndMigrateIfNeeded(arguments.wallet, market.baseAssetSymbol)
      .balanceInPips;

    uint64 oraclePriceInPips = Validations.validateOraclePriceAndConvertToPips(
      oraclePrice,
      arguments.collateralAssetDecimals,
      market,
      arguments.oracleWalletAddress
    );
    int64 expectedLiquidationQuoteQuantitiesInPips = LiquidationValidations
      .calculateLiquidationQuoteQuantityInPips(
        market.maintenanceMarginFractionInPips,
        oraclePriceInPips,
        positionSizeInPips,
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips
      );
    require(
      expectedLiquidationQuoteQuantitiesInPips - 1 <=
        liquidationQuoteQuantitiesInPips &&
        expectedLiquidationQuoteQuantitiesInPips + 1 >=
        liquidationQuoteQuantitiesInPips,
      'Invalid liquidation quote quantity'
    );

    balanceTracking.updateForLiquidation(
      arguments.wallet,
      arguments.insuranceFundWalletAddress,
      market.baseAssetSymbol,
      arguments.collateralAssetSymbol,
      liquidationQuoteQuantitiesInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
    );
  }

  function loadTotalAccountValueAndMarginRequirement(
    LiquidateArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) private returns (int64, uint64) {
    int64 totalAccountValueInPips = Margin.loadTotalAccountValue(
      Margin.LoadMarginRequirementArguments(
        arguments.wallet,
        arguments.oraclePrices,
        arguments.oracleWalletAddress,
        arguments.collateralAssetDecimals,
        arguments.collateralAssetSymbol
      ),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    uint64 totalMaintenanceMarginRequirementInPips = Margin
      .loadTotalMaintenanceMarginRequirementAndUpdateLastOraclePrice(
        Margin.LoadMarginRequirementArguments(
          arguments.wallet,
          arguments.oraclePrices,
          arguments.oracleWalletAddress,
          arguments.collateralAssetDecimals,
          arguments.collateralAssetSymbol
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
      );

    return (totalAccountValueInPips, totalMaintenanceMarginRequirementInPips);
  }

  function loadTotalAccountValueAndMarginRequirement(
    DeleverageArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) private returns (int64, uint64) {
    int64 totalAccountValueInPips = Margin.loadTotalAccountValue(
      Margin.LoadMarginRequirementArguments(
        arguments.liquidatingWallet,
        arguments.oraclePrices,
        arguments.oracleWalletAddress,
        arguments.collateralAssetDecimals,
        arguments.collateralAssetSymbol
      ),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    uint64 totalMaintenanceMarginRequirementInPips = Margin
      .loadTotalMaintenanceMarginRequirementAndUpdateLastOraclePrice(
        Margin.LoadMarginRequirementArguments(
          arguments.liquidatingWallet,
          arguments.oraclePrices,
          arguments.oracleWalletAddress,
          arguments.collateralAssetDecimals,
          arguments.collateralAssetSymbol
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
      );

    return (totalAccountValueInPips, totalMaintenanceMarginRequirementInPips);
  }
}
