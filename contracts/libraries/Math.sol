// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.13;

library Math {
  function multiplyPipsByFraction(
    uint64 multiplicand,
    uint64 fractionDividend,
    uint64 fractionDivisor
  ) internal pure returns (uint64) {
    uint256 dividend = uint256(multiplicand) * fractionDividend;
    uint256 result = dividend / fractionDivisor;

    require(result < 2**64, 'Pip quantity overflows uint64');

    return uint64(result);
  }
}
