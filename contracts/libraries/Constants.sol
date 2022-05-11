// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.13;

/**
 * @dev See GOVERNANCE.md for descriptions of fixed parameters and fees
 */

library Constants {
  // 100 basis points/percent * 100 percent/total
  uint64 public constant basisPointsInTotal = 100 * 100;

  uint64 public constant depositIndexNotSet = 2**64 - 1;

  uint8 public constant maxMarketCount = 50;

  // 20%
  uint64 public constant maxFeeBasisPoints = 20 * 100;

  uint64 public constant msInOneHour = 1000 * 60 * 60;

  uint8 public constant signatureHashVersion = 5;

  // To convert integer pips to a fractional price shift decimal left by the pip precision of 8
  // decimals places
  uint64 public constant pipPriceMultiplier = 10**8;

  // To convert percentage pips to a fraction, shift decimal left by the pip precision of 8
  // decimals places * 100 percent/total
  uint64 public constant percentagePipsInTotal = 10**8 * 100;
}
