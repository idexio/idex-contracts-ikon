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

pragma solidity 0.8.15;

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

  function loadOutstandingWalletFunding(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsBySymbol,
    mapping(address => string[]) storage marketSymbolsWithOpenPositionsByWallet
  ) public view returns (int64 fundingInPips) {
    return
      Funding.loadOutstandingWalletFunding(
        wallet,
        balanceTracking,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsBySymbol,
        marketSymbolsWithOpenPositionsByWallet
      );
  }

  function loadTotalAccountValueIncludingOutstandingWalletFunding(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 collateralAssetDecimals,
    string memory collateralAssetSymbol,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsBySymbol,
    mapping(address => string[]) storage marketSymbolsWithOpenPositionsByWallet
  ) public view returns (int64) {
    return
      Margin.loadTotalAccountValue(
        wallet,
        oraclePrices,
        collateralAssetDecimals,
        collateralAssetSymbol,
        oracleWalletAddress,
        balanceTracking,
        marketsBySymbol,
        marketSymbolsWithOpenPositionsByWallet
      ) +
      loadOutstandingWalletFunding(
        wallet,
        balanceTracking,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsBySymbol,
        marketSymbolsWithOpenPositionsByWallet
      );
  }

  function loadTotalInitialMarginRequirement(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 collateralAssetDecimals,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => Market) storage marketsBySymbol,
    mapping(address => string[]) storage marketSymbolsWithOpenPositionsByWallet
  ) public view returns (uint64 initialMarginRequirement) {
    return
      Margin.loadTotalInitialMarginRequirement(
        wallet,
        oraclePrices,
        collateralAssetDecimals,
        oracleWalletAddress,
        balanceTracking,
        marketsBySymbol,
        marketSymbolsWithOpenPositionsByWallet
      );
  }

  function loadTotalMaintenanceMarginRequirement(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 collateralAssetDecimals,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => Market) storage marketsBySymbol,
    mapping(address => string[]) storage marketSymbolsWithOpenPositionsByWallet
  ) public view returns (uint64 initialMarginRequirement) {
    return
      Margin.loadTotalMaintenanceMarginRequirement(
        wallet,
        oraclePrices,
        collateralAssetDecimals,
        oracleWalletAddress,
        balanceTracking,
        marketsBySymbol,
        marketSymbolsWithOpenPositionsByWallet
      );
  }

  function liquidate(
    LiquidateArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsBySymbol,
    mapping(address => string[]) storage marketSymbolsWithOpenPositionsByWallet
  ) public {
    Funding.updateWalletFunding(
      arguments.walletAddress,
      arguments.collateralAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsBySymbol,
      marketSymbolsWithOpenPositionsByWallet
    );

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
          marketsBySymbol,
          marketSymbolsWithOpenPositionsByWallet
        ),
        Margin.loadTotalMaintenanceMarginRequirementAndUpdateLastOraclePrice(
          arguments.walletAddress,
          arguments.oraclePrices,
          arguments.collateralAssetDecimals,
          arguments.oracleWalletAddress,
          balanceTracking,
          marketsBySymbol,
          marketSymbolsWithOpenPositionsByWallet
        )
      );

    require(
      totalAccountValueInPips <= int64(totalMaintenanceMarginRequirementInPips),
      'Maintenance margin met'
    );

    string[] memory marketSymbols = marketSymbolsWithOpenPositionsByWallet[
      arguments.walletAddress
    ];
    for (uint8 i = 0; i < marketSymbols.length; i++) {
      // FIXME Insurance fund margin requirements
      liquidateMarket(
        marketsBySymbol[marketSymbols[i]],
        arguments.liquidationQuoteQuantitiesInPips[i],
        arguments.oraclePrices[i],
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips,
        arguments,
        balanceTracking,
        marketSymbolsWithOpenPositionsByWallet
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
    mapping(address => string[]) storage marketSymbolsWithOpenPositionsByWallet
  ) public {
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
      liquidationQuoteQuantitiesInPips,
      marketSymbolsWithOpenPositionsByWallet
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
    mapping(string => Market) storage marketsBySymbol,
    mapping(address => string[]) storage marketSymbolsWithOpenPositionsByWallet
  ) public {
    Funding.updateWalletFunding(
      wallet,
      collateralAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsBySymbol,
      marketSymbolsWithOpenPositionsByWallet
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
