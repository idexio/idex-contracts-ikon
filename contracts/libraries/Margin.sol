// SPDX-License-Identifier: LGPL-3.0-only

import { AssetUnitConversions } from './AssetUnitConversions.sol';
import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { Math } from './Math.sol';
import { String } from './String.sol';
import { Validations } from './Validations.sol';
import { Market, OraclePrice } from './Structs.sol';

pragma solidity 0.8.13;

library Margin {
  using BalanceTracking for BalanceTracking.Storage;

  function loadTotalAccountValue(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 collateralAssetDecimals,
    string memory collateralAssetSymbol,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    Market[] storage markets
  ) internal view returns (int64) {
    int64 totalAccountValueInPips = balanceTracking
      .loadBalanceInPipsFromMigrationSourceIfNeeded(
        wallet,
        collateralAssetSymbol
      );

    for (uint8 i = 0; i < markets.length; i++) {
      Market memory market = markets[i];
      uint64 oraclePriceInPips = Validations
        .validateOraclePriceAndConvertToPips(
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

  function loadTotalInitialMarginRequirement(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 collateralAssetDecimals,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    Market[] storage markets
  ) internal view returns (uint64 initialMarginRequirement) {
    for (uint8 i = 0; i < markets.length; i++) {
      (Market memory market, OraclePrice memory oraclePrice) = (
        markets[i],
        oraclePrices[i]
      );

      initialMarginRequirement += loadMarginRequirement(
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

  function loadTotalMaintenanceMarginRequirement(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 collateralAssetDecimals,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    Market[] storage markets
  ) internal view returns (uint64 initialMarginRequirement) {
    for (uint8 i = 0; i < markets.length; i++) {
      (Market memory market, OraclePrice memory oraclePrice) = (
        markets[i],
        oraclePrices[i]
      );

      initialMarginRequirement += loadMarginRequirement(
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

  function loadMarginRequirement(
    address wallet,
    string memory baseAssetSymbol,
    uint64 marginFractionInPips,
    OraclePrice memory oraclePrice,
    uint8 collateralAssetDecimals,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking
  ) internal view returns (uint64) {
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
      loadTotalAccountValue(
        walletAddress,
        oraclePrices,
        collateralAssetDecimals,
        collateralAssetSymbol,
        oracleWalletAddress,
        balanceTracking,
        markets
      ) >=
      int64(
        loadTotalInitialMarginRequirement(
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
