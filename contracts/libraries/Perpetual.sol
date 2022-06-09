// SPDX-License-Identifier: LGPL-3.0-only

import { AssetUnitConversions } from './AssetUnitConversions.sol';
import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { FundingMultipliers } from './FundingMultipliers.sol';
import { Math } from './Math.sol';
import { String } from './String.sol';
import { Validations } from './Validations.sol';
import { FundingMultiplierQuartet, Market, OraclePrice } from './Structs.sol';

import 'hardhat/console.sol';

pragma solidity 0.8.13;

// TODO Gas optimization - several of the functions here iterate over all a wallet's position, potentially these
// multiple iterations could be combined
library Perpetual {
  using BalanceTracking for BalanceTracking.Storage;
  using FundingMultipliers for FundingMultiplierQuartet[];

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

  function liquidate(
    LiquidateArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    Market[] storage markets
  ) public {
    Perpetual.updateWalletFundingInternal(
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
        calculateTotalAccountValue(
          arguments.walletAddress,
          arguments.oraclePrices,
          arguments.collateralAssetDecimals,
          arguments.collateralAssetSymbol,
          arguments.oracleWalletAddress,
          balanceTracking,
          markets
        ),
        calculateTotalMaintenanceMarginRequirement(
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
    uint64 oraclePriceInPips = validateOraclePriceAndConvertToPips(
      oraclePrice,
      arguments.collateralAssetDecimals,
      market,
      arguments.oracleWalletAddress
    );

    BalanceTracking.Balance storage basePosition = balanceTracking
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
    for (uint8 i = 0; i < oraclePrices.length; i++) {
      (OraclePrice memory oraclePrice, int64 fundingRateInPips) = (
        oraclePrices[i],
        fundingRatesInPips[i]
      );
      uint64 oraclePriceInPips = validateOraclePriceAndConvertToPips(
        oraclePrice,
        collateralAssetDecimals,
        oracleWalletAddress
      );

      uint64 lastPublishTimestampInMs = lastFundingRatePublishTimestampInMsByBaseAssetSymbol[
          oraclePrice.baseAssetSymbol
        ];
      require(
        lastPublishTimestampInMs > 0
          ? lastPublishTimestampInMs + Constants.msInOneHour ==
            oraclePrice.timestampInMs
          : oraclePrice.timestampInMs % Constants.msInOneHour == 0,
        'Input price not hour-aligned'
      );

      // TODO Cleanup typecasts
      int64 newFundingMultiplier = Math.multiplyPipsByFraction(
        int64(oraclePriceInPips),
        fundingRateInPips,
        int64(Constants.pipPriceMultiplier)
      );
      if (
        fundingMultipliersByBaseAssetSymbol[oraclePrice.baseAssetSymbol]
          .length > 0
      ) {
        FundingMultiplierQuartet
          storage fundingMultipliers = fundingMultipliersByBaseAssetSymbol[
            oraclePrice.baseAssetSymbol
          ][
            fundingMultipliersByBaseAssetSymbol[oraclePrice.baseAssetSymbol]
              .length - 1
          ];
        if (fundingMultipliers.fundingMultiplier3 != 0) {
          fundingMultipliersByBaseAssetSymbol[oraclePrice.baseAssetSymbol].push(
              FundingMultiplierQuartet(newFundingMultiplier, 0, 0, 0)
            );
        } else if (fundingMultipliers.fundingMultiplier1 == 0) {
          fundingMultipliers.fundingMultiplier1 = newFundingMultiplier;
        } else if (fundingMultipliers.fundingMultiplier2 == 0) {
          fundingMultipliers.fundingMultiplier2 = newFundingMultiplier;
        } else {
          fundingMultipliers.fundingMultiplier3 = newFundingMultiplier;
        }
      } else {
        fundingMultipliersByBaseAssetSymbol[oraclePrice.baseAssetSymbol].push(
          FundingMultiplierQuartet(newFundingMultiplier, 0, 0, 0)
        );
      }
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol[
        oraclePrice.baseAssetSymbol
      ] = oraclePrice.timestampInMs;
    }
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
    int64 fundingInPips;
    int64 marketFundingInPips;
    uint64 lastFundingMultiplierTimestampInMs;

    for (uint8 marketIndex = 0; marketIndex < markets.length; marketIndex++) {
      Market memory market = markets[marketIndex];
      BalanceTracking.Balance storage basePosition = balanceTracking
        .loadBalanceAndMigrateIfNeeded(wallet, market.baseAssetSymbol);

      (
        marketFundingInPips,
        lastFundingMultiplierTimestampInMs
      ) = calculateWalletFundingForMarket(
        basePosition,
        market,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol
      );
      fundingInPips += marketFundingInPips;
      basePosition.lastUpdateTimestampInMs = lastFundingMultiplierTimestampInMs;
    }

    BalanceTracking.Balance storage collateralBalance = balanceTracking
      .loadBalanceAndMigrateIfNeeded(wallet, collateralAssetSymbol);
    collateralBalance.balanceInPips += fundingInPips;
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
    int64 totalAccountValueInPips = balanceTracking
      .loadBalanceInPipsFromMigrationSourceIfNeeded(
        wallet,
        collateralAssetSymbol
      );

    for (uint8 i = 0; i < markets.length; i++) {
      Market memory market = markets[i];
      uint64 oraclePriceInPips = validateOraclePriceAndConvertToPips(
        oraclePrices[i],
        collateralAssetDecimals,
        market,
        oracleWalletAddress
      );

      totalAccountValueInPips += Math.multiplyPipsByFraction(
        balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
          wallet,
          market.baseAssetSymbol
        ),
        int64(oraclePriceInPips),
        int64(Constants.pipPriceMultiplier)
      );
    }

    return totalAccountValueInPips;
  }

  function calculateTotalInitialMarginRequirement(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 collateralAssetDecimals,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    Market[] storage markets
  ) public view returns (uint64 initialMarginRequirement) {
    for (uint8 i = 0; i < markets.length; i++) {
      (Market memory market, OraclePrice memory oraclePrice) = (
        markets[i],
        oraclePrices[i]
      );

      initialMarginRequirement += calculateMarginRequirement(
        wallet,
        market.baseAssetSymbol,
        market.initialMarginFractionInPips,
        oraclePrice,
        collateralAssetDecimals,
        oracleWalletAddress,
        balanceTracking
      );
    }
  }

  function calculateTotalMaintenanceMarginRequirement(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 collateralAssetDecimals,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    Market[] storage markets
  ) public view returns (uint64 initialMarginRequirement) {
    for (uint8 i = 0; i < markets.length; i++) {
      (Market memory market, OraclePrice memory oraclePrice) = (
        markets[i],
        oraclePrices[i]
      );

      initialMarginRequirement += calculateMarginRequirement(
        wallet,
        market.baseAssetSymbol,
        market.maintenanceMarginFractionInPips,
        oraclePrice,
        collateralAssetDecimals,
        oracleWalletAddress,
        balanceTracking
      );
    }
  }

  function calculateMarginRequirement(
    address wallet,
    string memory baseAssetSymbol,
    uint64 marginFractionInPips,
    OraclePrice memory oraclePrice,
    uint8 collateralAssetDecimals,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking
  ) public view returns (uint64) {
    require(
      String.isStringEqual(baseAssetSymbol, oraclePrice.baseAssetSymbol),
      'Oracle price mismatch'
    );
    Validations.validateOraclePriceSignature(oraclePrice, oracleWalletAddress);

    return
      Math.abs(
        Math.multiplyPipsByFraction(
          Math.multiplyPipsByFraction(
            balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
              wallet,
              baseAssetSymbol
            ),
            int64(
              AssetUnitConversions.assetUnitsToPips(
                oraclePrice.priceInAssetUnits,
                collateralAssetDecimals
              )
            ),
            int64(Constants.pipPriceMultiplier)
          ),
          int64(marginFractionInPips),
          int64(Constants.pipPriceMultiplier)
        )
      );
  }

  function calculateWalletFundingForMarket(
    BalanceTracking.Balance memory basePosition,
    Market memory market,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol
  )
    internal
    view
    returns (int64 fundingInPips, uint64 lastFundingMultiplierTimestampInMs)
  {
    // Load funding rates and index
    FundingMultiplierQuartet[]
      storage fundingMultipliersForMarket = fundingMultipliersByBaseAssetSymbol[
        market.baseAssetSymbol
      ];
    lastFundingMultiplierTimestampInMs = lastFundingRatePublishTimestampInMsByBaseAssetSymbol[
      market.baseAssetSymbol
    ];

    // Apply hourly funding payments if new rates were published since this balance was last updated
    if (
      basePosition.balanceInPips != 0 &&
      basePosition.lastUpdateTimestampInMs < lastFundingMultiplierTimestampInMs
    ) {
      int64 aggregateFundingMultiplier = fundingMultipliersForMarket
        .loadAggregateMultiplier(
          basePosition.lastUpdateTimestampInMs,
          lastFundingMultiplierTimestampInMs
        );

      fundingInPips += Math.multiplyPipsByFraction(
        basePosition.balanceInPips,
        aggregateFundingMultiplier,
        int64(Constants.pipPriceMultiplier)
      );
    }
  }

  function updateWalletFundingInternal(
    address walletAddress,
    string memory collateralAssetSymbol,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    Market[] storage markets
  ) internal {
    updateWalletFunding(
      walletAddress,
      collateralAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      markets
    );
  }

  function updateWalletsFunding(
    address wallet1,
    address wallet2,
    string memory collateralAssetSymbol,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    Market[] storage markets
  ) internal {
    updateWalletFunding(
      wallet1,
      collateralAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      markets
    );
    updateWalletFunding(
      wallet2,
      collateralAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      markets
    );
  }

  function isInitialMarginRequirementMet(
    address walletAddress,
    OraclePrice[] memory oraclePrices,
    uint8 collateralAssetDecimals,
    string memory collateralAssetSymbol,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    Market[] storage markets
  ) internal view returns (bool) {
    return
      calculateTotalAccountValue(
        walletAddress,
        oraclePrices,
        collateralAssetDecimals,
        collateralAssetSymbol,
        oracleWalletAddress,
        balanceTracking,
        markets
      ) >=
      int64(
        calculateTotalInitialMarginRequirement(
          walletAddress,
          oraclePrices,
          collateralAssetDecimals,
          oracleWalletAddress,
          balanceTracking,
          markets
        )
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

  function validateOraclePriceAndConvertToPips(
    OraclePrice memory oraclePrice,
    uint8 collateralAssetDecimals,
    Market memory market,
    address oracleWalletAddress
  ) private pure returns (uint64) {
    require(
      String.isStringEqual(market.baseAssetSymbol, oraclePrice.baseAssetSymbol),
      'Oracle price mismatch'
    );

    return
      validateOraclePriceAndConvertToPips(
        oraclePrice,
        collateralAssetDecimals,
        oracleWalletAddress
      );
  }

  function validateOraclePriceAndConvertToPips(
    OraclePrice memory oraclePrice,
    uint8 collateralAssetDecimals,
    address oracleWalletAddress
  ) private pure returns (uint64) {
    // TODO Validate timestamp recency
    Validations.validateOraclePriceSignature(oraclePrice, oracleWalletAddress);

    return
      AssetUnitConversions.assetUnitsToPips(
        oraclePrice.priceInAssetUnits,
        collateralAssetDecimals
      );
  }
}
