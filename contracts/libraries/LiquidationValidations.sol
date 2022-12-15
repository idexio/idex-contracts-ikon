// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { Constants } from "./Constants.sol";
import { Math } from "./Math.sol";

import "hardhat/console.sol";

library LiquidationValidations {
  function calculateExitQuoteQuantity(
    int64 costBasis,
    uint64 indexPrice,
    int64 positionSize
  ) internal pure returns (int64 quoteQuantity) {
    quoteQuantity = Math.multiplyPipsByFraction(positionSize, int64(indexPrice), int64(Constants.PIP_PRICE_MULTIPLIER));

    // Quote value is the worse of the index price or entry price. For long positions, quote is positive so at a worse
    // price quote is closer to zero (receive less); for short positions, quote is negative so at a worse price is
    // further from zero (give more)
    quoteQuantity = Math.min(quoteQuantity, costBasis);
  }

  function calculateExitQuoteQuantity(
    int64 costBasis,
    uint64 indexPrice,
    int64 positionSize,
    int64 totalAccountValue
  ) internal pure returns (int64 quoteQuantity) {
    // Quote value is the worse of the index price or entry price...
    quoteQuantity = calculateExitQuoteQuantity(costBasis, indexPrice, positionSize);

    // ...but never worse than the bankruptcy price. For long positions, quote is positive so at a better price quote
    // is further from zero (receive more); for short positions, quote is negative so at a better price is closer to
    // zero (give less)
    quoteQuantity = Math.max(
      quoteQuantity,
      _calculateLiquidationQuoteQuantityToZeroOutAccountValue(indexPrice, positionSize, totalAccountValue)
    );
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
    int64 baseQuantity,
    uint64 indexPrice,
    int64 quoteQuantity,
    int64 totalAccountValue
  ) internal pure {
    int64 expectedLiquidationQuoteQuantity;
    if (totalAccountValue < 0) {
      // Use bankruptcy price for negative total account value
      expectedLiquidationQuoteQuantity = _calculateLiquidationQuoteQuantityToZeroOutAccountValue(
        indexPrice,
        baseQuantity,
        totalAccountValue
      );
    } else {
      // Use index price for positive totalAccountValue
      expectedLiquidationQuoteQuantity = Math.multiplyPipsByFraction(
        baseQuantity,
        int64(indexPrice),
        int64(Constants.PIP_PRICE_MULTIPLIER)
      );
    }

    require(
      expectedLiquidationQuoteQuantity - 1 <= quoteQuantity && expectedLiquidationQuoteQuantity + 1 >= quoteQuantity,
      "Invalid quote quantity"
    );
  }

  function validateExitQuoteQuantity(
    int64 costBasis,
    int64 exitQuoteQuantity,
    uint64 indexPrice,
    int64 positionSize,
    int64 totalAccountValue
  ) internal pure {
    int64 expectedExitQuoteQuantity = LiquidationValidations.calculateExitQuoteQuantity(
      costBasis,
      indexPrice,
      positionSize,
      totalAccountValue
    );
    require(
      expectedExitQuoteQuantity - 1 <= exitQuoteQuantity && expectedExitQuoteQuantity + 1 >= exitQuoteQuantity,
      "Invalid exit quote quantity"
    );
  }

  function validateInsuranceFundClosureQuoteQuantity(
    int64 baseQuantity,
    int64 costBasis,
    int64 positionSize,
    int64 quoteQuantity
  ) internal pure {
    int64 expectedLiquidationQuoteQuantities = -1 * Math.multiplyPipsByFraction(costBasis, baseQuantity, positionSize);

    require(
      expectedLiquidationQuoteQuantities - 1 <= quoteQuantity &&
        expectedLiquidationQuoteQuantities + 1 >= quoteQuantity,
      "Invalid quote quantity"
    );
  }

  function validateLiquidationQuoteQuantityToClosePositions(
    int64 liquidationQuoteQuantity,
    uint64 marginFraction,
    uint64 indexPrice,
    int64 positionSize,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement
  ) internal pure {
    int64 expectedLiquidationQuoteQuantities = _calculateLiquidationQuoteQuantityToClosePositions(
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
    uint64 maintenanceMarginFraction,
    uint64 indexPrice,
    int64 positionSize,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement
  ) private pure returns (int64) {
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

    return int64(quoteQuantity);
  }

  function _calculateLiquidationQuoteQuantityToZeroOutAccountValue(
    uint64 indexPrice,
    int64 positionSize,
    int64 totalAccountValue
  ) private pure returns (int64) {
    int256 positionNotionalValueInDoublePips = int256(positionSize) * int64(indexPrice);
    int256 totalAccountValueInDoublePips = int256(totalAccountValue) * int64(Constants.PIP_PRICE_MULTIPLIER);

    int256 quoteQuantity = (positionNotionalValueInDoublePips - totalAccountValueInDoublePips) /
      int64(Constants.PIP_PRICE_MULTIPLIER);
    require(quoteQuantity < 2 ** 63, "Pip quantity overflows int64");
    require(quoteQuantity > -2 ** 63, "Pip quantity underflows int64");

    return int64(quoteQuantity);
  }
}
