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
        Math.multiplyPipsByFraction(
          int64(
            AssetUnitConversions.assetUnitsToPips(
              oraclePrice.priceInAssetUnits,
              collateralAssetDecimals
            )
          ),
          fundingRateInPips,
          int64(Constants.pipPriceMultiplier)
        )
      );
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol[
        oraclePrice.baseAssetSymbol
      ] = oraclePrice.timestampInMs;
    }
  }

  function updateWalletFunding(
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
        basePosition.balanceInPips != 0 &&
        basePosition.lastUpdateTimestampInMs <
        lastFundingMultiplierTimestampInMs
      ) {
        uint256 hoursSinceLastUpdate = (lastFundingMultiplierTimestampInMs -
          basePosition.lastUpdateTimestampInMs) / Constants.msInOneHour;
        int64 positionSizeInPips = basePosition.balanceInPips;

        for (
          uint256 multiplierIndex = hoursSinceLastUpdate >
            fundingMultipliers.length
            ? 0
            : fundingMultipliers.length - hoursSinceLastUpdate;
          multiplierIndex < fundingMultipliers.length;
          multiplierIndex++
        ) {
          fundingInPips += Math.multiplyPipsByFraction(
            positionSizeInPips,
            fundingMultipliers[multiplierIndex],
            int64(Constants.pipPriceMultiplier)
          );
        }

        basePosition
          .lastUpdateTimestampInMs = lastFundingMultiplierTimestampInMs;
      }
    }

    BalanceTracking.Balance storage collateralBalance = balanceTracking
      .loadBalanceAndMigrateIfNeeded(wallet, collateralAssetSymbol);
    collateralBalance.balanceInPips += fundingInPips;
  }

  function updateWalletFundingInternal(
    address walletAddress,
    string memory collateralAssetSymbol,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => int64[]) storage fundingMultipliersByBaseAssetSymbol,
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
    mapping(string => int64[]) storage fundingMultipliersByBaseAssetSymbol,
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
}
