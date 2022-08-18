// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.15;

import { Constants } from './Constants.sol';

library LiquidationValidations {
  function calculateLiquidationQuoteQuantityInPips(
    uint64 maintenanceMarginFractionInPips,
    uint64 oraclePriceInPips,
    int64 positionSizeInPips,
    int64 totalAccountValueInPips,
    uint64 totalMaintenanceMarginRequirementInPips
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

  function validateLiquidationQuoteQuantity(
    int64 liquidationQuoteQuantityInPips,
    uint64 marginFractionInPips,
    uint64 oraclePriceInPips,
    int64 positionSizeInPips,
    int64 totalAccountValueInPips,
    uint64 totalMaintenanceMarginRequirementInPips
  ) internal pure {
    int64 expectedLiquidationQuoteQuantitiesInPips = LiquidationValidations
      .calculateLiquidationQuoteQuantityInPips(
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
}
