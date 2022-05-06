// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.13;

/**
 * @dev See GOVERNANCE.md for descriptions of fixed parameters and fees
 */

library Constants {
  // 100 basis points/percent * 100 percent/total
  uint64 public constant basisPointsInTotal = 100 * 100;

  uint64 public constant depositIndexNotSet = 2**64 - 1;

  // 20%
  uint64 public constant maxFeeBasisPoints = 20 * 100;

  uint8 public constant signatureHashVersion = 5;
}
