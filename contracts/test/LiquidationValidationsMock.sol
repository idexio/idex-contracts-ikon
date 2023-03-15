// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { LiquidationValidations } from "../libraries/LiquidationValidations.sol";

contract LiquidationValidationsMock {
  function calculateLiquidationQuoteQuantityToClosePositions(
    uint64 indexPrice,
    uint64 maintenanceMarginFraction,
    int64 positionSize,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement
  ) public pure returns (uint64) {
    return
      LiquidationValidations.calculateLiquidationQuoteQuantityToClosePositions(
        indexPrice,
        maintenanceMarginFraction,
        positionSize,
        totalAccountValue,
        totalMaintenanceMarginRequirement
      );
  }
}
