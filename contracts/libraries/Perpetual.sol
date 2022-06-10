// SPDX-License-Identifier: LGPL-3.0-only

import { AssetUnitConversions } from './AssetUnitConversions.sol';
import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { Funding } from './Funding.sol';
import { FundingMultipliers } from './FundingMultipliers.sol';
import { Margin } from './Margin.sol';
import { Math } from './Math.sol';
import { String } from './String.sol';
import { Validations } from './Validations.sol';
import { Balance, FundingMultiplierQuartet, Market, OraclePrice } from './Structs.sol';

pragma solidity 0.8.13;

// TODO Gas optimization - several of the functions here iterate over all a wallet's position, potentially these
// multiple iterations could be combined
library Perpetual {
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

  function calculateOutstandingWalletFunding(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    Market[] storage markets
  ) public view returns (int64 fundingInPips) {
    return
      Funding.calculateOutstandingWalletFunding(
        wallet,
        balanceTracking,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        markets
      );
  }

  function calculateTotalAccountValue(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 collateralAssetDecimals,
    string memory collateralAssetSymbol,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    Market[] storage markets
  ) public view returns (int64) {
    return
      Margin.calculateTotalAccountValue(
        wallet,
        oraclePrices,
        collateralAssetDecimals,
        collateralAssetSymbol,
        oracleWalletAddress,
        balanceTracking,
        markets
      );
  }

  function calculateTotalInitialMarginRequirement(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 collateralAssetDecimals,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    Market[] storage markets
  ) public view returns (uint64 initialMarginRequirement) {
    return
      Margin.calculateTotalInitialMarginRequirement(
        wallet,
        oraclePrices,
        collateralAssetDecimals,
        oracleWalletAddress,
        balanceTracking,
        markets
      );
  }

  function calculateTotalMaintenanceMarginRequirement(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 collateralAssetDecimals,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    Market[] storage markets
  ) public view returns (uint64 initialMarginRequirement) {
    return
      Margin.calculateTotalMaintenanceMarginRequirement(
        wallet,
        oraclePrices,
        collateralAssetDecimals,
        oracleWalletAddress,
        balanceTracking,
        markets
      );
  }

  function liquidate(
    LiquidateArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    Market[] storage markets
  ) public {
    Funding.updateWalletFunding(
      arguments.walletAddress,
      arguments.collateralAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      markets
    );

    (
      int64 totalAccountValueInPips,
      uint64 totalMaintenanceMarginRequirementInPips
    ) = (
        Margin.calculateTotalAccountValue(
          arguments.walletAddress,
          arguments.oraclePrices,
          arguments.collateralAssetDecimals,
          arguments.collateralAssetSymbol,
          arguments.oracleWalletAddress,
          balanceTracking,
          markets
        ),
        Margin.calculateTotalMaintenanceMarginRequirement(
          arguments.walletAddress,
          arguments.oraclePrices,
          arguments.collateralAssetDecimals,
          arguments.oracleWalletAddress,
          balanceTracking,
          markets
        )
      );

    require(
      totalAccountValueInPips <= int64(totalMaintenanceMarginRequirementInPips),
      'Maintenance margin met'
    );

    for (uint8 i = 0; i < markets.length; i++) {
      // FIXME Insurance fund margin requirements
      liquidateMarket(
        markets[i],
        arguments.liquidationQuoteQuantitiesInPips[i],
        arguments.oraclePrices[i],
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips,
        arguments,
        balanceTracking
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
    BalanceTracking.Storage storage balanceTracking
  ) public {
    uint64 oraclePriceInPips = Validations.validateOraclePriceAndConvertToPips(
      oraclePrice,
      arguments.collateralAssetDecimals,
      market,
      arguments.oracleWalletAddress
    );

    Balance storage basePosition = balanceTracking
      .loadBalanceAndMigrateIfNeeded(
        arguments.walletAddress,
        market.baseAssetSymbol
      );

    int64 positionSizeInPips = basePosition.balanceInPips;
    // Gas optimization - move on to next market if wallet has no position in this one
    if (positionSizeInPips == 0) {
      return;
    }

    int64 expectedLiquidationQuoteQuantitiesInPips = calculateLiquidationQuoteQuantityInPips(
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
      liquidationQuoteQuantitiesInPips
    );
  }

  function publishFundingMutipliers(
    OraclePrice[] memory oraclePrices,
    int64[] memory fundingRatesInPips,
    uint8 collateralAssetDecimals,
    address oracleWalletAddress,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol
  ) public {
    Funding.publishFundingMutipliers(
      oraclePrices,
      fundingRatesInPips,
      collateralAssetDecimals,
      oracleWalletAddress,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol
    );
  }

  function updateWalletFunding(
    address wallet,
    string memory collateralAssetSymbol,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    Market[] storage markets
  ) public {
    Funding.updateWalletFunding(
      wallet,
      collateralAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      markets
    );
  }

  function calculateLiquidationQuoteQuantityInPips(
    int64 positionSizeInPips,
    uint64 oraclePriceInPips,
    int64 totalAccountValueInPips,
    uint64 totalMaintenanceMarginRequirementInPips,
    uint64 maintenanceMarginFractionInPips
  ) private pure returns (int64) {
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
}
