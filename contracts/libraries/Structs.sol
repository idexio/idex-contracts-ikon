// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.13;

import { OrderSelfTradePrevention, OrderSide, OrderTimeInForce, OrderType } from './Enums.sol';

struct DelegatedKeyAuthorization {
  // UUIDv1 unique to wallet
  uint128 nonce;
  // Public component of ECDSA signing key pair
  address delegatedPublicKey;
  // ECDSA signature of hash by delegate private key
  bytes signature;
}

struct FundingMultipliers {
  int64 fundingMultiplier1;
  int64 fundingMultiplier2;
  int64 fundingMultiplier3;
  int64 fundingMultiplier4;
}

struct Market {
  // Flag to distinguish from empty struct
  bool exists;
  // No need to specify quote asset - it is always the same as the collateral asset
  string baseAssetSymbol;
  // The margin fraction needed to open a position
  uint64 initialMarginFractionInPips;
  // The margin fraction required to prevent liquidation
  uint64 maintenanceMarginFractionInPips;
  // The increase of initialMarginFraction for each incrementalPositionSize above the
  // baselinePositionSize
  uint64 incrementalInitialMarginFractionInPips;
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
  // Signature from oracle wallet
  bytes signature;
}

/**
 * @notice Argument type for `Exchange.executeOrderBookTrade` and `Hashing.getOrderWalletHash`
 */
struct Order {
  // Must equal `Constants.signatureHashVersion`
  uint8 signatureHashVersion;
  // UUIDv1 unique to wallet
  uint128 nonce;
  // Custody wallet address that placed order and (if not using delegate wallet) signed hash
  address walletAddress;
  // Type of order
  OrderType orderType;
  // Order side wallet is on
  OrderSide side;
  // Order quantity in base or quote asset terms depending on isQuantityInQuote flag
  uint64 quantityInPips;
  // Is quantityInPips in quote terms
  bool isQuantityInQuote;
  // For limit orders, price in decimal pips * 10^8 in quote terms
  uint64 limitPriceInPips;
  // For stop orders, stop loss or take profit price in decimal pips * 10^8 in quote terms
  uint64 stopPriceInPips;
  // Optional custom client order ID
  string clientOrderId;
  // TIF option specified by wallet for order
  OrderTimeInForce timeInForce;
  // STP behavior specified by wallet for order
  OrderSelfTradePrevention selfTradePrevention;
  // Cancellation time specified by wallet for GTT TIF order
  uint64 cancelAfter;
  // The ECDSA signature of the order hash as produced by Hashing.getOrderWalletHash
  bytes walletSignature;
  // Asserted when signed by delegated key instead of custody wallet
  bool isSignedByDelegatedKey;
  // If non-zero, an authorization for a delegate key signer authorized by the custody wallet
  DelegatedKeyAuthorization delegatedKeyAuthorization;
}

/**
 * @notice Argument type for `Exchange.executeOrderBookTrade` specifying execution parameters for matching orders
 */
struct OrderBookTrade {
  // Base asset symbol
  string baseAssetSymbol;
  // Quote asset symbol
  string quoteAssetSymbol;
  // Amount of base asset executed
  uint64 baseQuantityInPips;
  // Amount of quote asset executed
  uint64 quoteQuantityInPips;
  // Fee paid by (or, if negative, rebated to) liquidity maker in quote (collateral) asset
  int64 makerFeeQuantityInPips;
  // Fee paid by liquidity taker in quote (collateral) asset
  uint64 takerFeeQuantityInPips;
  // Execution price of trade in decimal pips * 10^8 in quote terms
  uint64 priceInPips;
  // Which side of the order (buy or sell) the liquidity maker was on
  OrderSide makerSide;
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
