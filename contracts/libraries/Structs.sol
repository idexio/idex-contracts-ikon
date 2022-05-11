// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.13;

struct Market {
  // Flag to distinguish from empty struct
  bool exists;
  // No need to specify quote asset - it is always the same as the collateral asset
  string baseAssetSymbol;
  // The margin fraction needed to open a position
  uint64 initialMarginFractionInBasisPoints;
  // The margin fraction required to prevent liquidation
  uint64 maintenanceMarginFractionInBasisPoints;
  // The increase of initialMarginFraction for each incrementalPositionSize above the
  // baselinePositionSize
  uint64 incrementalInitialMarginFractionInBasisPoints;
  // The max position size in base token before increasing the initial-margin-fraction.
  uint64 baselinePositionSizeInPips;
  // The step size (in base token) for increasing the initialMarginFraction by
  // (incrementalInitialMarginFraction per step)
  uint64 incrementalPositionSizeInPips;
  // The max position size in base token
  uint64 maximumPositionSizeInPips;
}

// Price data signed by oracle wallet
struct OraclePrice {
  string baseAssetSymbol;
  // Milliseconds since epoch
  uint64 timestampInMs;
  // Price of base asset in quote asset units
  uint256 priceInAssetUnits;
  // Off-chain derived funding rate
  int64 fundingRateInPercentagePips;
  // Signature from oracle wallet
  bytes signature;
}

/**
 * @notice Internally used struct capturing wallet order nonce invalidations created via `invalidateOrderNonce`
 */
struct NonceInvalidation {
  bool exists;
  uint64 timestampInMs;
  uint256 effectiveBlockNumber;
}

/**
 * @notice Argument type for `Exchange.withdraw` and `Hashing.getWithdrawalWalletHash`
 */
struct Withdrawal {
  // UUIDv1 unique to wallet
  uint128 nonce;
  // Address of wallet to which funds will be returned
  address payable walletAddress;
  // Withdrawal quantity
  uint64 grossQuantityInPips;
  // Gas fee deducted from withdrawn quantity to cover dispatcher tx costs
  uint64 gasFeeInPips;
  // The ECDSA signature of the withdrawal hash as produced by Hashing.getWithdrawalWalletHash
  bytes walletSignature;
}
