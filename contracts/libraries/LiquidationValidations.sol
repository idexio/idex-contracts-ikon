// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { Math as OpenZeppelinMath } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { SignedMath } from "@openzeppelin/contracts/utils/math/SignedMath.sol";

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
    int256 totalAccountValueInDoublePips,
    uint256 totalMaintenanceMarginRequirementInTriplePips
  ) internal pure returns (uint64) {
    if (totalMaintenanceMarginRequirementInTriplePips == 0) {
      return 0;
    }

    int256 quoteQuantityInDoublePips = int256(positionSize) * Math.toInt64(indexPrice);

    uint256 quotePenaltyInDoublePipsUnsigned = OpenZeppelinMath.mulDiv(
      SignedMath.abs(quoteQuantityInDoublePips) * maintenanceMarginFraction,
      SignedMath.abs(totalAccountValueInDoublePips),
      totalMaintenanceMarginRequirementInTriplePips
    );

    int256 quotePenaltyInDoublePips = (totalAccountValueInDoublePips < 0 ? int256(1) : int256(-1)) *
      SafeCast.toInt256(quotePenaltyInDoublePipsUnsigned);

    int256 quoteQuantity = (quoteQuantityInDoublePips + quotePenaltyInDoublePips) /
      (Math.toInt64(Constants.PIP_PRICE_MULTIPLIER));

    // Under certain extreme pricing scenarios, liquidating a short position requires sending the liquidating wallet
    // quote as well as base. While this is correct per the above calculation it would necessitate signed handling
    // elsewhere and be counterintuitive to deleveraged positions, so instead coerce to zero. A similar result can
    // occur for long positions requiring taking both base and quote from the liquidating wallet, though in practice
    // such a wallet would meet the margin requirement and therefor not need liquidation; we include the latter check
    // here anyway for completeness
    if ((positionSize < 0 && quoteQuantity > 0) || (positionSize > 0 && quoteQuantity < 0)) {
      return 0;
    }

    return Math.abs(Math.toInt64(quoteQuantity));
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
      expectedLiquidationQuoteQuantity - (expectedLiquidationQuoteQuantity == 0 ? 0 : 1) <= quoteQuantity &&
        expectedLiquidationQuoteQuantity + 1 >= quoteQuantity,
      "Invalid quote quantity"
    );
  }

  function validateExitFundClosureQuoteQuantity(
    uint64 indexPrice,
    bool isPositionBelowMinimum,
    int64 liquidationBaseQuantity,
    uint64 liquidationQuoteQuantity,
    uint64 maintenanceMarginFraction,
    int256 totalAccountValueInDoublePips,
    uint256 totalMaintenanceMarginRequirementInTriplePips
  ) internal pure {
    uint64 expectedLiquidationQuoteQuantity;
    if (totalAccountValueInDoublePips < 0) {
      // Use bankruptcy price for negative total account value
      expectedLiquidationQuoteQuantity = calculateQuoteQuantityAtBankruptcyPrice(
        indexPrice,
        maintenanceMarginFraction,
        liquidationBaseQuantity,
        totalAccountValueInDoublePips,
        totalMaintenanceMarginRequirementInTriplePips
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
      expectedLiquidationQuoteQuantity - (expectedLiquidationQuoteQuantity == 0 ? 0 : 1) <= liquidationQuoteQuantity &&
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
      expectedLiquidationQuoteQuantity - (expectedLiquidationQuoteQuantity == 0 ? 0 : 1) <= liquidationQuoteQuantity &&
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
      expectedLiquidationQuoteQuantity - (expectedLiquidationQuoteQuantity == 0 ? 0 : 1) <= quoteQuantity &&
        expectedLiquidationQuoteQuantity + 1 >= quoteQuantity,
      "Invalid quote quantity"
    );
  }

  function validateQuoteQuantityAtBankruptcyPrice(
    uint64 indexPrice,
    int64 liquidationBaseQuantity,
    uint64 liquidationQuoteQuantity,
    uint64 maintenanceMarginFraction,
    int256 totalAccountValueInDoublePips,
    uint256 totalMaintenanceMarginRequirementInTriplePips
  ) internal pure {
    uint64 expectedLiquidationQuoteQuantity = calculateQuoteQuantityAtBankruptcyPrice(
      indexPrice,
      maintenanceMarginFraction,
      liquidationBaseQuantity,
      totalAccountValueInDoublePips,
      totalMaintenanceMarginRequirementInTriplePips
    );

    // Allow additional pip buffers for integer rounding
    require(
      expectedLiquidationQuoteQuantity - (expectedLiquidationQuoteQuantity == 0 ? 0 : 1) <= liquidationQuoteQuantity &&
        expectedLiquidationQuoteQuantity + 1 >= liquidationQuoteQuantity,
      "Invalid quote quantity"
    );
  }
}
