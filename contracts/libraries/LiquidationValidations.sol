// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { Constants } from "./Constants.sol";
import { Math } from "./Math.sol";

library LiquidationValidations {
  function calculateExitQuoteQuantity(
    int64 costBasis,
    uint64 indexPrice,
    int64 positionSize
  ) internal pure returns (uint64 quoteQuantity) {
    quoteQuantity = Math.multiplyPipsByFraction(Math.abs(positionSize), indexPrice, Constants.PIP_PRICE_MULTIPLIER);

    // Quote value is the worse of the index price or entry price. For long positions, quote is positive so at a worse
    // price quote is closer to zero (receive less); for short positions, quote is negative so at a worse price is
    // further from zero (give more)
    quoteQuantity = positionSize < 0
      ? Math.max(quoteQuantity, Math.abs(costBasis))
      : Math.min(quoteQuantity, Math.abs(costBasis));

    return quoteQuantity;
  }

  function calculateExitQuoteQuantity(
    int64 costBasis,
    uint64 indexPrice,
    uint64 maintenanceMarginFraction,
    int64 positionSize,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement
  ) internal pure returns (uint64 quoteQuantity) {
    // Quote value is the worse of the index price or entry price...
    quoteQuantity = calculateExitQuoteQuantity(costBasis, indexPrice, positionSize);

    // ...but never worse than the bankruptcy price. For long positions, quote is positive so at a better price quote
    // is further from zero (receive more); for short positions, quote is negative so at a better price is closer to
    // zero (give less)
    uint64 quoteQuantityToLiquidate = _calculateLiquidationQuoteQuantityToClosePositions(
      indexPrice,
      maintenanceMarginFraction,
      positionSize,
      totalAccountValue,
      totalMaintenanceMarginRequirement
    );
    quoteQuantity = positionSize < 0
      ? Math.min(quoteQuantity, quoteQuantityToLiquidate)
      : Math.max(quoteQuantity, quoteQuantityToLiquidate);
  }

  function validateDeactivatedMarketLiquidationQuoteQuantity(
    uint64 indexPrice,
    int64 positionSize,
    int64 quoteQuantity
  ) internal pure {
    int64 expectedLiquidationQuoteQuantities = Math.multiplyPipsByFraction(
      positionSize,
      int64(indexPrice),
      int64(Constants.PIP_PRICE_MULTIPLIER)
    );

    require(
      expectedLiquidationQuoteQuantities - 1 <= quoteQuantity &&
        expectedLiquidationQuoteQuantities + 1 >= quoteQuantity,
      "Invalid quote quantity"
    );
  }

  function validateExitFundClosureQuoteQuantity(
    int64 positionSize,
    uint64 indexPrice,
    uint64 maintenanceMarginFraction,
    uint64 quoteQuantity,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement
  ) internal pure {
    uint64 expectedLiquidationQuoteQuantity;
    if (totalAccountValue < 0) {
      // Use bankruptcy price for negative total account value
      expectedLiquidationQuoteQuantity = _calculateLiquidationQuoteQuantityToClosePositions(
        indexPrice,
        maintenanceMarginFraction,
        positionSize,
        totalAccountValue,
        totalMaintenanceMarginRequirement
      );
    } else {
      // Use index price for positive totalAccountValue
      expectedLiquidationQuoteQuantity = Math.abs(
        Math.multiplyPipsByFraction(positionSize, int64(indexPrice), int64(Constants.PIP_PRICE_MULTIPLIER))
      );
    }

    require(
      expectedLiquidationQuoteQuantity - 1 <= quoteQuantity && expectedLiquidationQuoteQuantity + 1 >= quoteQuantity,
      "Invalid quote quantity"
    );
  }

  function validateExitQuoteQuantity(
    int64 costBasis,
    uint64 exitQuoteQuantity,
    uint64 indexPrice,
    uint64 maintenanceMarginFraction,
    int64 positionSize,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement
  ) internal pure {
    uint64 expectedExitQuoteQuantity = calculateExitQuoteQuantity(
      costBasis,
      indexPrice,
      maintenanceMarginFraction,
      positionSize,
      totalAccountValue,
      totalMaintenanceMarginRequirement
    );
    require(
      expectedExitQuoteQuantity - 1 <= exitQuoteQuantity && expectedExitQuoteQuantity + 1 >= exitQuoteQuantity,
      "Invalid exit quote quantity"
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
      Math.abs(positionSize)
    );

    require(
      expectedLiquidationQuoteQuantity - 1 <= quoteQuantity && expectedLiquidationQuoteQuantity + 1 >= quoteQuantity,
      "Invalid quote quantity"
    );
  }

  function validateLiquidationQuoteQuantityToClosePositions(
    uint64 liquidationQuoteQuantity,
    uint64 marginFraction,
    uint64 indexPrice,
    int64 positionSize,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement
  ) internal pure {
    uint64 expectedLiquidationQuoteQuantities = _calculateLiquidationQuoteQuantityToClosePositions(
      marginFraction,
      indexPrice,
      positionSize,
      totalAccountValue,
      totalMaintenanceMarginRequirement
    );
    require(
      expectedLiquidationQuoteQuantities - 1 <= liquidationQuoteQuantity &&
        expectedLiquidationQuoteQuantities + 1 >= liquidationQuoteQuantity,
      "Invalid liquidation quote quantity"
    );
  }

  // Private //

  function _calculateLiquidationQuoteQuantityToClosePositions(
    uint64 indexPrice,
    uint64 maintenanceMarginFraction,
    int64 positionSize,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement
  ) private pure returns (uint64) {
    int256 quoteQuantityInDoublePips = int256(positionSize) * int64(indexPrice);

    int256 quotePenaltyInDoublePips = ((positionSize < 0 ? int256(1) : int256(-1)) *
      quoteQuantityInDoublePips *
      int64(maintenanceMarginFraction) *
      totalAccountValue) /
      int64(totalMaintenanceMarginRequirement) /
      int64(Constants.PIP_PRICE_MULTIPLIER);

    int256 quoteQuantity = (quoteQuantityInDoublePips + quotePenaltyInDoublePips) /
      (int64(Constants.PIP_PRICE_MULTIPLIER));
    require(quoteQuantity < 2 ** 63, "Pip quantity overflows int64");
    require(quoteQuantity > -2 ** 63, "Pip quantity underflows int64");

    return Math.abs(int64(quoteQuantity));
  }
}
