// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.15;

/**
 * @dev See GOVERNANCE.md for descriptions of fixed parameters and fees
 */

library Constants {
  // 100 basis points/percent * 100 percent/total
  uint64 public constant basisPointsInTotal = 100 * 100;

  uint64 public constant depositIndexNotSet = 2**64 - 1;

  // 1 week at 3s/block
  uint256 public constant maxChainPropagationPeriodInBlocks =
    (7 * 24 * 60 * 60) / 3;

  // 1 year
  uint256 public constant maxDelegateKeyExpirationPeriodInMs =
    365 * 24 * 60 * 60 * 1000;

  // 20%
  uint64 public constant maxFeeBasisPoints = 20 * 100;

  uint64 public constant msInOneHour = 1000 * 60 * 60;

  uint8 public constant signatureHashVersion = 5;

  // To convert integer pips to a fractional price shift decimal left by the pip precision of 8
  // decimals places
  uint64 public constant pipPriceMultiplier = 10**8;
}
