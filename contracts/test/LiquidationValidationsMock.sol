// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { LiquidationValidations } from "../libraries/LiquidationValidations.sol";

contract LiquidationValidationsMock {
  function calculateQuoteQuantityAtBankruptcyPrice(
    uint64 indexPrice,
    uint64 maintenanceMarginFraction,
    int64 positionSize,
    int256 totalAccountValueInDoublePips,
    uint256 totalMaintenanceMarginRequirementInTriplePips
  ) public pure returns (uint64) {
    return
      LiquidationValidations.calculateQuoteQuantityAtBankruptcyPrice(
        indexPrice,
        maintenanceMarginFraction,
        positionSize,
        totalAccountValueInDoublePips,
        totalMaintenanceMarginRequirementInTriplePips
      );
  }

  function validateDeactivatedMarketLiquidationQuoteQuantity(
    uint64 indexPrice,
    int64 positionSize,
    uint64 quoteQuantity
  ) public pure {
    LiquidationValidations.validateDeactivatedMarketLiquidationQuoteQuantity(indexPrice, positionSize, quoteQuantity);
  }

  function validateQuoteQuantityAtExitPrice(
    int64 costBasis,
    uint64 indexPrice,
    int64 liquidationBaseQuantity,
    uint64 liquidationQuoteQuantity
  ) public pure {
    LiquidationValidations.validateQuoteQuantityAtExitPrice(
      costBasis,
      indexPrice,
      liquidationBaseQuantity,
      liquidationQuoteQuantity
    );
  }

  function validateInsuranceFundClosureQuoteQuantity(
    uint64 baseQuantity,
    int64 costBasis,
    int64 positionSize,
    uint64 quoteQuantity
  ) public pure {
    LiquidationValidations.validateInsuranceFundClosureQuoteQuantity(
      baseQuantity,
      costBasis,
      positionSize,
      quoteQuantity
    );
  }

  function validateQuoteQuantityAtBankruptcyPrice(
    uint64 indexPrice,
    int64 liquidationBaseQuantity,
    uint64 liquidationQuoteQuantity,
    uint64 maintenanceMarginFraction,
    int256 totalAccountValueInDoublePips,
    uint256 totalMaintenanceMarginRequirementInTriplePips
  ) public pure {
    LiquidationValidations.validateQuoteQuantityAtBankruptcyPrice(
      indexPrice,
      liquidationBaseQuantity,
      liquidationQuoteQuantity,
      maintenanceMarginFraction,
      totalAccountValueInDoublePips,
      totalMaintenanceMarginRequirementInTriplePips
    );
  }
}
