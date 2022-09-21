// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

library Math {
  function abs(int64 signed) internal pure returns (uint64) {
    return uint64(signed < 0 ? -1 * signed : signed);
  }

  function max(int64 a, int64 b) internal pure returns (int64) {
    return a >= b ? a : b;
  }

  function min(int64 a, int64 b) internal pure returns (int64) {
    return a <= b ? a : b;
  }

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

  function multiplyPipsByFraction(
    int64 multiplicand,
    int64 fractionDividend,
    int64 fractionDivisor
  ) internal pure returns (int64) {
    int256 dividend = int256(multiplicand) * fractionDividend;
    int256 result = dividend / fractionDivisor;

    require(result < 2**63, 'Pip quantity overflows int64');
    require(result > -2**63, 'Pip quantity underflows int64');

    return int64(result);
  }
}
