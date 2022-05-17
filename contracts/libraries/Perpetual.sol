// SPDX-License-Identifier: LGPL-3.0-only

import { AssetUnitConversions } from './AssetUnitConversions.sol';
import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { Math } from './Math.sol';
import { String } from './String.sol';
import { Validations } from './Validations.sol';
import { Market, OraclePrice } from './Structs.sol';

pragma solidity 0.8.13;

library Perpetual {
  using BalanceTracking for BalanceTracking.Storage;

  function publishFundingMutipliers(
    OraclePrice[] memory oraclePrices,
    int64[] memory fundingRatesInPips,
    uint8 collateralAssetDecimals,
    address oracleWalletAddress,
    mapping(string => int64[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol
  ) public {
    for (uint8 i = 0; i < oraclePrices.length; i++) {
      (OraclePrice memory oraclePrice, int64 fundingRateInPips) = (
        oraclePrices[i],
        fundingRatesInPips[i]
      );

      Validations.validateOraclePriceSignature(
        oraclePrice,
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
      fundingMultipliersByBaseAssetSymbol[oraclePrice.baseAssetSymbol].push(
        int64(
          (int256(
            uint256(
              AssetUnitConversions.assetUnitsToPips(
                oraclePrice.priceInAssetUnits,
                collateralAssetDecimals
              )
            )
          ) * int256(fundingRateInPips))
        )
      );
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol[
        oraclePrice.baseAssetSymbol
      ] = oraclePrice.timestampInMs;
    }
  }

  function updateAccountFunding(
    address wallet,
    string memory collateralAssetSymbol,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => int64[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    Market[] storage markets
  ) public {
    int64 fundingInPips;

    for (uint8 marketIndex = 0; marketIndex < markets.length; marketIndex++) {
      Market memory market = markets[marketIndex];
      BalanceTracking.Balance storage basePosition = balanceTracking
        .loadBalanceAndMigrateIfNeeded(wallet, market.baseAssetSymbol);

      (
        int64[] storage fundingMultipliers,
        uint64 lastFundingMultiplierTimestampInMs
      ) = (
          fundingMultipliersByBaseAssetSymbol[market.baseAssetSymbol],
          lastFundingRatePublishTimestampInMsByBaseAssetSymbol[
            market.baseAssetSymbol
          ]
        );

      if (
        basePosition.balanceInPips > 0 &&
        basePosition.updatedTimestampInMs < lastFundingMultiplierTimestampInMs
      ) {
        uint256 hoursSinceLastUpdate = (lastFundingMultiplierTimestampInMs -
          basePosition.updatedTimestampInMs) / Constants.msInOneHour;

        for (
          uint256 multiplierIndex = fundingMultipliers.length -
            hoursSinceLastUpdate;
          multiplierIndex < fundingMultipliers.length;
          multiplierIndex++
        ) {
          fundingInPips +=
            fundingMultipliers[multiplierIndex] *
            basePosition.balanceInPips;
        }

        basePosition.updatedTimestampInMs = lastFundingMultiplierTimestampInMs;
      }
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
      (Market memory market, OraclePrice memory oraclePrice) = (
        markets[i],
        oraclePrices[i]
      );

      require(
        String.isStringEqual(
          market.baseAssetSymbol,
          oraclePrice.baseAssetSymbol
        ),
        'Oracle price mismatch'
      );
      Validations.validateOraclePriceSignature(
        oraclePrice,
        oracleWalletAddress
      );

      totalAccountValueInPips += Math.multiplyPipsByFraction(
        balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
          wallet,
          market.baseAssetSymbol
        ),
        int64(
          AssetUnitConversions.assetUnitsToPips(
            oraclePrice.priceInAssetUnits,
            collateralAssetDecimals
          )
        ),
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

      require(
        String.isStringEqual(
          market.baseAssetSymbol,
          oraclePrice.baseAssetSymbol
        ),
        'Oracle price mismatch'
      );
      Validations.validateOraclePriceSignature(
        oraclePrice,
        oracleWalletAddress
      );

      initialMarginRequirement += Math.abs(
        Math.multiplyPipsByFraction(
          Math.multiplyPipsByFraction(
            balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
              wallet,
              market.baseAssetSymbol
            ),
            int64(
              AssetUnitConversions.assetUnitsToPips(
                oraclePrice.priceInAssetUnits,
                collateralAssetDecimals
              )
            ),
            int64(Constants.pipPriceMultiplier)
          ),
          int64(market.initialMarginFractionInPips),
          int64(Constants.pipPriceMultiplier)
        )
      );
    }
  }
}
