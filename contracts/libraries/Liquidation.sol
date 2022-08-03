// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.15;

import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { Margin } from './Margin.sol';
import { Validations } from './Validations.sol';
import { Balance, Market, OraclePrice } from './Structs.sol';

library Liquidation {
  using BalanceTracking for BalanceTracking.Storage;

  struct LiquidateArguments {
    // External arguments
    address walletAddress;
    int64[] liquidationQuoteQuantitiesInPips;
    OraclePrice[] oraclePrices;
    // Exchange state
    uint8 collateralAssetDecimals;
    string collateralAssetSymbol;
    address insuranceFundWalletAddress;
    address oracleWalletAddress;
  }

  function calculateLiquidationQuoteQuantityInPips(
    int64 positionSizeInPips,
    uint64 oraclePriceInPips,
    int64 totalAccountValueInPips,
    uint64 totalMaintenanceMarginRequirementInPips,
    uint64 maintenanceMarginFractionInPips
  ) internal pure returns (int64) {
    int256 quoteQuantityInDoublePips = int256(positionSizeInPips) *
      int64(oraclePriceInPips);

    int256 quotePenaltyInDoublePips = ((
      positionSizeInPips < 0 ? int256(1) : int256(-1)
    ) *
      quoteQuantityInDoublePips *
      int64(maintenanceMarginFractionInPips) *
      totalAccountValueInPips) /
      int64(totalMaintenanceMarginRequirementInPips) /
      int64(Constants.pipPriceMultiplier);

    int256 quoteQuantityInPips = (quoteQuantityInDoublePips +
      quotePenaltyInDoublePips) / (int64(Constants.pipPriceMultiplier));
    require(quoteQuantityInPips < 2**63, 'Pip quantity overflows int64');
    require(quoteQuantityInPips > -2**63, 'Pip quantity underflows int64');

    return int64(quoteQuantityInPips);
  }

  function liquidate(
    LiquidateArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet
  ) internal {
    (
      int64 totalAccountValueInPips,
      uint64 totalMaintenanceMarginRequirementInPips
    ) = (
        Margin.loadTotalAccountValue(
          arguments.walletAddress,
          arguments.oraclePrices,
          arguments.collateralAssetDecimals,
          arguments.collateralAssetSymbol,
          arguments.oracleWalletAddress,
          balanceTracking,
          marketsByBaseAssetSymbol,
          baseAssetSymbolsWithOpenPositionsByWallet
        ),
        Margin.loadTotalMaintenanceMarginRequirementAndUpdateLastOraclePrice(
          arguments.walletAddress,
          arguments.oraclePrices,
          arguments.collateralAssetDecimals,
          arguments.oracleWalletAddress,
          balanceTracking,
          marketsByBaseAssetSymbol,
          baseAssetSymbolsWithOpenPositionsByWallet
        )
      );

    require(
      totalAccountValueInPips <= int64(totalMaintenanceMarginRequirementInPips),
      'Maintenance margin met'
    );

    string[] memory marketSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
      arguments.walletAddress
    ];
    for (uint8 i = 0; i < marketSymbols.length; i++) {
      // FIXME Insurance fund margin requirements
      liquidateMarket(
        marketsByBaseAssetSymbol[marketSymbols[i]],
        arguments.liquidationQuoteQuantitiesInPips[i],
        arguments.oraclePrices[i],
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips,
        arguments,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet
      );
    }
  }

  function liquidateMarket(
    Market memory market,
    int64 liquidationQuoteQuantitiesInPips,
    OraclePrice memory oraclePrice,
    int64 totalAccountValueInPips,
    uint64 totalMaintenanceMarginRequirementInPips,
    LiquidateArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet
  ) private {
    int64 positionSizeInPips = balanceTracking
      .loadBalanceAndMigrateIfNeeded(
        arguments.walletAddress,
        market.baseAssetSymbol
      )
      .balanceInPips;

    uint64 oraclePriceInPips = Validations.validateOraclePriceAndConvertToPips(
      oraclePrice,
      arguments.collateralAssetDecimals,
      market,
      arguments.oracleWalletAddress
    );
    int64 expectedLiquidationQuoteQuantitiesInPips = Liquidation
      .calculateLiquidationQuoteQuantityInPips(
        positionSizeInPips,
        oraclePriceInPips,
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips,
        market.maintenanceMarginFractionInPips
      );
    require(
      expectedLiquidationQuoteQuantitiesInPips - 1 <=
        liquidationQuoteQuantitiesInPips &&
        expectedLiquidationQuoteQuantitiesInPips + 1 >=
        liquidationQuoteQuantitiesInPips,
      'Invalid liquidation quote quantity'
    );

    balanceTracking.updateForLiquidation(
      arguments.walletAddress,
      arguments.insuranceFundWalletAddress,
      market.baseAssetSymbol,
      arguments.collateralAssetSymbol,
      liquidationQuoteQuantitiesInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
    );
  }
}
