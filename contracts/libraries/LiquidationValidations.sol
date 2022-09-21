// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { Constants } from './Constants.sol';
import { Math } from './Math.sol';

library LiquidationValidations {
  function calculateExitQuoteQuantityInPips(
    int64 costBasisInPips,
    uint64 maintenanceMarginFractionInPips,
    uint64 oraclePriceInPips,
    int64 positionSizeInPips,
    int64 totalAccountValueInPips,
    uint64 totalMaintenanceMarginRequirementInPips
  ) internal pure returns (int64 quoteQuantityInPips) {
    quoteQuantityInPips = Math.multiplyPipsByFraction(
      positionSizeInPips,
      int64(oraclePriceInPips),
      int64(Constants.pipPriceMultiplier)
    );

    // Quote value is the lesser of the oracle price or entry price...
    quoteQuantityInPips = Math.min(quoteQuantityInPips, costBasisInPips);

    // ...but never less than the bankruptcy price
    quoteQuantityInPips = Math.max(
      quoteQuantityInPips,
      calculateLiquidationQuoteQuantityInPips(
        maintenanceMarginFractionInPips,
        oraclePriceInPips,
        positionSizeInPips,
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips
      )
    );
  }

  function validateDustLiquidationQuoteQuantity(
    uint64 dustPositionLiquidationPriceToleranceBasisPoints,
    int64 liquidationQuoteQuantityInPips,
    uint64 oraclePriceInPips,
    int64 positionSizeInPips
  ) internal pure {
    int64 expectedLiquidationQuoteQuantitiesInPips = Math
      .multiplyPipsByFraction(
        positionSizeInPips,
        int64(oraclePriceInPips),
        int64(Constants.pipPriceMultiplier)
      );
    uint64 toleranceInPips = (dustPositionLiquidationPriceToleranceBasisPoints *
      Math.abs(expectedLiquidationQuoteQuantitiesInPips)) /
      Constants.basisPointsInTotal;

    require(
      expectedLiquidationQuoteQuantitiesInPips - int64(toleranceInPips) <=
        liquidationQuoteQuantityInPips &&
        expectedLiquidationQuoteQuantitiesInPips + int64(toleranceInPips) >=
        liquidationQuoteQuantityInPips,
      'Invalid liquidation quote quantity'
    );
  }

  function validateExitQuoteQuantity(
    int64 costBasisInPips,
    int64 liquidationQuoteQuantityInPips,
    uint64 marginFractionInPips,
    uint64 oraclePriceInPips,
    int64 positionSizeInPips,
    int64 totalAccountValueInPips,
    uint64 totalMaintenanceMarginRequirementInPips
  ) internal pure {
    int64 expectedLiquidationQuoteQuantitiesInPips = LiquidationValidations
      .calculateExitQuoteQuantityInPips(
        costBasisInPips,
        marginFractionInPips,
        oraclePriceInPips,
        positionSizeInPips,
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips
      );
    require(
      expectedLiquidationQuoteQuantitiesInPips - 1 <=
        liquidationQuoteQuantityInPips &&
        expectedLiquidationQuoteQuantitiesInPips + 1 >=
        liquidationQuoteQuantityInPips,
      'Invalid liquidation quote quantity'
    );
  }

  function validateExitFundClosureQuoteQuantityInPips(
    int64 baseQuantityInPips,
    uint64 maintenanceMarginFractionInPips,
    uint64 oraclePriceInPips,
    int64 positionSizeInPips,
    int64 quoteQuantityInPips,
    int64 totalAccountValueInPips,
    uint64 totalMaintenanceMarginRequirementInPips
  ) internal pure {
    int64 expectedLiquidationQuoteQuantitiesInPips;
    if (positionSizeInPips < 0) {
      // Use bankruptcy price for negative position
      expectedLiquidationQuoteQuantitiesInPips = calculateLiquidationQuoteQuantityInPips(
        maintenanceMarginFractionInPips,
        oraclePriceInPips,
        baseQuantityInPips,
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips
      );
    } else {
      // Use oracle price for positive position
      expectedLiquidationQuoteQuantitiesInPips = Math.multiplyPipsByFraction(
        baseQuantityInPips,
        int64(oraclePriceInPips),
        int64(Constants.pipPriceMultiplier)
      );
    }

    require(
      expectedLiquidationQuoteQuantitiesInPips - 1 <= quoteQuantityInPips &&
        expectedLiquidationQuoteQuantitiesInPips + 1 >= quoteQuantityInPips,
      'Invalid quote quantity'
    );
  }

  function validateInsuranceFundClosureQuoteQuantityInPips(
    int64 baseQuantityInPips,
    int64 costBasisInPips,
    int64 positionSizeInPips,
    int64 quoteQuantityInPips
  ) internal pure {
    int64 expectedLiquidationQuoteQuantitiesInPips = Math
      .multiplyPipsByFraction(
        costBasisInPips,
        baseQuantityInPips,
        positionSizeInPips
      );

    require(
      expectedLiquidationQuoteQuantitiesInPips - 1 <= quoteQuantityInPips &&
        expectedLiquidationQuoteQuantitiesInPips + 1 >= quoteQuantityInPips,
      'Invalid quote quantity'
    );
  }

  function validateLiquidationQuoteQuantity(
    int64 liquidationQuoteQuantityInPips,
    uint64 marginFractionInPips,
    uint64 oraclePriceInPips,
    int64 positionSizeInPips,
    int64 totalAccountValueInPips,
    uint64 totalMaintenanceMarginRequirementInPips
  ) internal pure {
    int64 expectedLiquidationQuoteQuantitiesInPips = calculateLiquidationQuoteQuantityInPips(
        marginFractionInPips,
        oraclePriceInPips,
        positionSizeInPips,
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips
      );
    require(
      expectedLiquidationQuoteQuantitiesInPips - 1 <=
        liquidationQuoteQuantityInPips &&
        expectedLiquidationQuoteQuantitiesInPips + 1 >=
        liquidationQuoteQuantityInPips,
      'Invalid liquidation quote quantity'
    );
  }

  function calculateLiquidationQuoteQuantityInPips(
    uint64 maintenanceMarginFractionInPips,
    uint64 oraclePriceInPips,
    int64 positionSizeInPips,
    int64 totalAccountValueInPips,
    uint64 totalMaintenanceMarginRequirementInPips
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
