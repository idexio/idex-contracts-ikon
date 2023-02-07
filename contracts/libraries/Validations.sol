// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Constants } from "./Constants.sol";
import { Math } from "./Math.sol";
import { Market, IndexPrice } from "./Structs.sol";

library Validations {
  function isFeeQuantityValid(uint64 fee, uint64 total) internal pure returns (bool) {
    uint64 feeMultiplier = Math.multiplyPipsByFraction(fee, Constants.PIP_PRICE_MULTIPLIER, total);

    return feeMultiplier <= Constants.MAX_FEE_MULTIPLIER;
  }
}
