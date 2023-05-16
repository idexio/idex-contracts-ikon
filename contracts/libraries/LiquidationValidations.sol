// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Constants } from "./Constants.sol";
import { Math } from "./Math.sol";

library LiquidationValidations {
  function calculateQuoteQuantityAtExitPrice(
    int64 costBasis,
    uint64 indexPrice,
    int64 positionSize
  ) internal pure returns (uint64 quoteQuantity) {
    // Calculate quote quantity at index price
    quoteQuantity = Math.multiplyPipsByFraction(Math.abs(positionSize), indexPrice, Constants.PIP_PRICE_MULTIPLIER);
    // Quote quantity is the worse of the index price or entry price. For long positions, quote is positive so at a
    // worse price quote is closer to zero (receive less); for short positions, quote is negative so at a worse price
    // is further from zero (give more)
    quoteQuantity = positionSize < 0
      ? Math.max(quoteQuantity, Math.abs(costBasis))
      : Math.min(quoteQuantity, Math.abs(costBasis));
  }

  /**
   * @dev Calculates quote quantity needed to close position at bankruptcy price
   */
  function calculateQuoteQuantityAtBankruptcyPrice(
    uint64 indexPrice,
    uint64 maintenanceMarginFraction,
    int64 positionSize,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement
  ) internal pure returns (uint64) {
    if (totalMaintenanceMarginRequirement == 0) {
      return 0;
    }

    int256 quoteQuantityInDoublePips = int256(positionSize) * Math.toInt64(indexPrice);

    int256 quotePenaltyInDoublePips = ((positionSize < 0 ? int256(1) : int256(-1)) *
      quoteQuantityInDoublePips *
      Math.toInt64(maintenanceMarginFraction) *
      totalAccountValue) /
      Math.toInt64(totalMaintenanceMarginRequirement) /
      Math.toInt64(Constants.PIP_PRICE_MULTIPLIER);

    int256 quoteQuantity = (quoteQuantityInDoublePips + quotePenaltyInDoublePips) /
      (Math.toInt64(Constants.PIP_PRICE_MULTIPLIER));
    require(quoteQuantity <= type(int64).max, "Pip quantity overflows int64");
    require(quoteQuantity >= type(int64).min, "Pip quantity underflows int64");

    return Math.abs(int64(quoteQuantity));
  }

  function validateDeactivatedMarketLiquidationQuoteQuantity(
    uint64 indexPrice,
    int64 positionSize,
    uint64 quoteQuantity
  ) internal pure {
    uint64 expectedLiquidationQuoteQuantity = Math.multiplyPipsByFraction(
      Math.abs(positionSize),
      indexPrice,
      Constants.PIP_PRICE_MULTIPLIER
    );

    // Allow additional pip buffers for integer rounding
    require(
      expectedLiquidationQuoteQuantity - 1 <= quoteQuantity && expectedLiquidationQuoteQuantity + 1 >= quoteQuantity,
      "Invalid quote quantity"
    );
  }

  function validateExitFundClosureQuoteQuantity(
    uint64 indexPrice,
    bool isPositionBelowMinimum,
    int64 liquidationBaseQuantity,
    uint64 liquidationQuoteQuantity,
    uint64 maintenanceMarginFraction,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement
  ) internal pure {
    uint64 expectedLiquidationQuoteQuantity;
    if (totalAccountValue < 0) {
      // Use bankruptcy price for negative total account value
      expectedLiquidationQuoteQuantity = calculateQuoteQuantityAtBankruptcyPrice(
        indexPrice,
        maintenanceMarginFraction,
        liquidationBaseQuantity,
        totalAccountValue,
        totalMaintenanceMarginRequirement
      );
    } else {
      // Use index price for positive total account value
      expectedLiquidationQuoteQuantity = Math.multiplyPipsByFraction(
        Math.abs(liquidationBaseQuantity),
        indexPrice,
        Constants.PIP_PRICE_MULTIPLIER
      );
    }

    // Skip validation for positions with very low quote values to avoid false positives due to rounding error
    if (
      isPositionBelowMinimum &&
      expectedLiquidationQuoteQuantity < Constants.MINIMUM_QUOTE_QUANTITY_VALIDATION_THRESHOLD &&
      liquidationQuoteQuantity < Constants.MINIMUM_QUOTE_QUANTITY_VALIDATION_THRESHOLD
    ) {
      return;
    }

    // Allow additional pip buffers for integer rounding
    require(
      expectedLiquidationQuoteQuantity - 1 <= liquidationQuoteQuantity &&
        expectedLiquidationQuoteQuantity + 1 >= liquidationQuoteQuantity,
      "Invalid quote quantity"
    );
  }

  function validateQuoteQuantityAtExitPrice(
    int64 costBasis,
    uint64 indexPrice,
    int64 liquidationBaseQuantity,
    uint64 liquidationQuoteQuantity
  ) internal pure {
    uint64 expectedLiquidationQuoteQuantity = calculateQuoteQuantityAtExitPrice(
      costBasis,
      indexPrice,
      liquidationBaseQuantity
    );

    // Allow additional pip buffers for integer rounding
    require(
      expectedLiquidationQuoteQuantity - 1 <= liquidationQuoteQuantity &&
        expectedLiquidationQuoteQuantity + 1 >= liquidationQuoteQuantity,
      "Invalid quote quantity"
    );
  }

  function validateInsuranceFundClosureQuoteQuantity(
    uint64 baseQuantity,
    int64 costBasis,
    int64 positionSize,
    uint64 quoteQuantity
  ) internal pure {
    uint64 expectedLiquidationQuoteQuantity = Math.multiplyPipsByFraction(
      Math.abs(costBasis),
      baseQuantity,
      Math.abs(positionSize) // Position size validated non-zero by calling function
    );

    // Allow additional pip buffers for integer rounding
    require(
      expectedLiquidationQuoteQuantity - 1 <= quoteQuantity && expectedLiquidationQuoteQuantity + 1 >= quoteQuantity,
      "Invalid quote quantity"
    );
  }

  function validateQuoteQuantityAtBankruptcyPrice(
    uint64 indexPrice,
    int64 liquidationBaseQuantity,
    uint64 liquidationQuoteQuantity,
    uint64 maintenanceMarginFraction,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement
  ) internal pure {
    uint64 expectedLiquidationQuoteQuantity = calculateQuoteQuantityAtBankruptcyPrice(
      indexPrice,
      maintenanceMarginFraction,
      liquidationBaseQuantity,
      totalAccountValue,
      totalMaintenanceMarginRequirement
    );

    // Allow additional pip buffers for integer rounding
    require(
      expectedLiquidationQuoteQuantity - 1 <= liquidationQuoteQuantity &&
        expectedLiquidationQuoteQuantity + 1 >= liquidationQuoteQuantity,
      "Invalid quote quantity"
    );
  }
}
