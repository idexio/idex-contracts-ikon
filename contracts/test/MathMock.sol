// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Math } from "../libraries/Math.sol";

contract MathMock {
  function divideRoundUp(uint64 a, uint64 b) public pure returns (uint64) {
    return Math.divideRoundUp(a, b);
  }

  function divideRoundNearest(uint64 a, uint64 b) public pure returns (uint64) {
    return Math.divideRoundNearest(a, b);
  }

  function maxUnsigned(uint64 a, uint64 b) public pure returns (uint64) {
    return Math.max(a, b);
  }

  function maxSigned(int64 a, int64 b) public pure returns (int64) {
    return Math.max(a, b);
  }

  function minUnsigned(uint64 a, uint64 b) public pure returns (uint64) {
    return Math.min(a, b);
  }

  function multiplyPipsByFractionUnsigned(
    uint64 multiplicand,
    uint64 fractionDividend,
    uint64 fractionDivisor
  ) public pure returns (uint64) {
    return Math.multiplyPipsByFraction(multiplicand, fractionDividend, fractionDivisor);
  }

  function multiplyPipsByFractionSigned(
    int64 multiplicand,
    int64 fractionDividend,
    int64 fractionDivisor
  ) public pure returns (int64) {
    return Math.multiplyPipsByFraction(multiplicand, fractionDividend, fractionDivisor);
  }
}
