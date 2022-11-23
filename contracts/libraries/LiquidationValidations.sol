// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { Constants } from './Constants.sol';
import { Math } from './Math.sol';

library LiquidationValidations {
  function calculateExitQuoteQuantity(
    int64 costBasis,
    uint64 oraclePrice,
    int64 positionSize,
    int64 totalAccountValue
  ) internal pure returns (int64 quoteQuantity) {
    quoteQuantity = Math.multiplyPipsByFraction(
      positionSize,
      int64(oraclePrice),
      int64(Constants.pipPriceMultiplier)
    );

    // Quote value is the worse of the oracle price or entry price...
    quoteQuantity = positionSize > 0
      ? Math.min(quoteQuantity, costBasis)
      : Math.max(quoteQuantity, costBasis);

    // ...but never worse than the bankruptcy price
    quoteQuantity = positionSize > 0
      ? Math.max(
        quoteQuantity,
        calculateLiquidationQuoteQuantityToZeroOutAccountValue(
          oraclePrice,
          positionSize,
          totalAccountValue
        )
      )
      : Math.min(
        quoteQuantity,
        calculateLiquidationQuoteQuantityToZeroOutAccountValue(
          oraclePrice,
          positionSize,
          totalAccountValue
        )
      );
  }

  function validateDeactivatedMarketLiquidationQuoteQuantity(
    uint64 oraclePrice,
    int64 positionSize,
    int64 quoteQuantity
  ) internal pure {
    int64 expectedLiquidationQuoteQuantities = Math.multiplyPipsByFraction(
      positionSize,
      int64(oraclePrice),
      int64(Constants.pipPriceMultiplier)
    );

    require(
      expectedLiquidationQuoteQuantities - 1 <= quoteQuantity &&
        expectedLiquidationQuoteQuantities + 1 >= quoteQuantity,
      'Invalid quote quantity'
    );
  }

  function validateExitFundClosureQuoteQuantity(
    int64 baseQuantity,
    uint64 oraclePrice,
    int64 positionSize,
    int64 quoteQuantity,
    int64 totalAccountValue
  ) internal pure {
    int64 expectedLiquidationQuoteQuantities;
    if (positionSize < 0) {
      // Use bankruptcy price for negative total account value
      expectedLiquidationQuoteQuantities = calculateLiquidationQuoteQuantityToZeroOutAccountValue(
        oraclePrice,
        baseQuantity,
        totalAccountValue
      );
    } else {
      // Use oracle price for positive position
      expectedLiquidationQuoteQuantities = Math.multiplyPipsByFraction(
        baseQuantity,
        int64(oraclePrice),
        int64(Constants.pipPriceMultiplier)
      );
    }

    require(
      expectedLiquidationQuoteQuantities - 1 <= quoteQuantity &&
        expectedLiquidationQuoteQuantities + 1 >= quoteQuantity,
      'Invalid quote quantity'
    );
  }

  function validateExitQuoteQuantity(
    int64 costBasis,
    int64 liquidationQuoteQuantity,
    uint64 oraclePrice,
    int64 positionSize,
    int64 totalAccountValue
  ) internal pure {
    int64 expectedLiquidationQuoteQuantities = LiquidationValidations
      .calculateExitQuoteQuantity(
        costBasis,
        oraclePrice,
        positionSize,
        totalAccountValue
      );
    require(
      expectedLiquidationQuoteQuantities - 1 <= liquidationQuoteQuantity &&
        expectedLiquidationQuoteQuantities + 1 >= liquidationQuoteQuantity,
      'Invalid liquidation quote quantity'
    );
  }

  function validateInsuranceFundClosureQuoteQuantity(
    int64 baseQuantity,
    int64 costBasis,
    int64 positionSize,
    int64 quoteQuantity
  ) internal pure {
    int64 expectedLiquidationQuoteQuantities = -1 *
      Math.multiplyPipsByFraction(costBasis, baseQuantity, positionSize);

    require(
      expectedLiquidationQuoteQuantities - 1 <= quoteQuantity &&
        expectedLiquidationQuoteQuantities + 1 >= quoteQuantity,
      'Invalid quote quantity'
    );
  }

  function validateLiquidationQuoteQuantityToClosePositions(
    int64 liquidationQuoteQuantity,
    uint64 marginFraction,
    uint64 oraclePrice,
    int64 positionSize,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement
  ) internal pure {
    int64 expectedLiquidationQuoteQuantities = calculateLiquidationQuoteQuantityToClosePositions(
        marginFraction,
        oraclePrice,
        positionSize,
        totalAccountValue,
        totalMaintenanceMarginRequirement
      );
    require(
      expectedLiquidationQuoteQuantities - 1 <= liquidationQuoteQuantity &&
        expectedLiquidationQuoteQuantities + 1 >= liquidationQuoteQuantity,
      'Invalid liquidation quote quantity'
    );
  }

  function validatePositionBelowMinimumLiquidationQuoteQuantity(
    uint64 positionBelowMinimumLiquidationPriceToleranceBasisPoints,
    int64 liquidationQuoteQuantity,
    uint64 oraclePrice,
    int64 positionSize
  ) internal pure {
    int64 expectedLiquidationQuoteQuantities = Math.multiplyPipsByFraction(
      positionSize,
      int64(oraclePrice),
      int64(Constants.pipPriceMultiplier)
    );
    uint64 tolerance = (positionBelowMinimumLiquidationPriceToleranceBasisPoints *
        Math.abs(expectedLiquidationQuoteQuantities)) /
        Constants.basisPointsInTotal;

    require(
      expectedLiquidationQuoteQuantities - int64(tolerance) <=
        liquidationQuoteQuantity &&
        expectedLiquidationQuoteQuantities + int64(tolerance) >=
        liquidationQuoteQuantity,
      'Invalid liquidation quote quantity'
    );
  }

  // Private //

  function calculateLiquidationQuoteQuantityToClosePositions(
    uint64 maintenanceMarginFraction,
    uint64 oraclePrice,
    int64 positionSize,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement
  ) private pure returns (int64) {
    int256 quoteQuantityInDoublePips = int256(positionSize) *
      int64(oraclePrice);

    int256 quotePenaltyInDoublePips = ((
      positionSize < 0 ? int256(1) : int256(-1)
    ) *
      quoteQuantityInDoublePips *
      int64(maintenanceMarginFraction) *
      totalAccountValue) /
      int64(totalMaintenanceMarginRequirement) /
      int64(Constants.pipPriceMultiplier);

    int256 quoteQuantity = (quoteQuantityInDoublePips +
      quotePenaltyInDoublePips) / (int64(Constants.pipPriceMultiplier));
    require(quoteQuantity < 2**63, 'Pip quantity overflows int64');
    require(quoteQuantity > -2**63, 'Pip quantity underflows int64');

    return int64(quoteQuantity);
  }

  function calculateLiquidationQuoteQuantityToZeroOutAccountValue(
    uint64 oraclePrice,
    int64 positionSize,
    int64 totalAccountValue
  ) private pure returns (int64) {
    int256 positionNotionalValueInDoublePips = int256(positionSize) *
      int64(oraclePrice);
    int256 totalAccountValueInDoublePips = int256(totalAccountValue) *
      int64(Constants.pipPriceMultiplier);

    int256 quoteQuantity = (positionNotionalValueInDoublePips -
      totalAccountValueInDoublePips) /
      (int256(positionSize) * int64(Constants.pipPriceMultiplier));
    require(quoteQuantity < 2**63, 'Pip quantity overflows int64');
    require(quoteQuantity > -2**63, 'Pip quantity underflows int64');

    return int64(quoteQuantity);
  }
}
