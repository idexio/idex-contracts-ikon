// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { AggregatorV3Interface as IChainlinkAggregator } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import { OrderSelfTradePrevention, OrderSide, OrderTimeInForce, OrderTriggerType, OrderType } from "./Enums.sol";

/**
 * @notice Internally used struct for tracking wallet balances and funding updates
 */
struct Balance {
  bool isMigrated;
  int64 balanceInPips;
  // The last funding update timestamp and cost basis are only relevant for base asset positions
  uint64 lastUpdateTimestampInMs;
  int64 costBasisInPips;
}

/**
 * @notice Field in `Order` struct for optionally authorizing a delegate key signing wallet
 */
struct DelegatedKeyAuthorization {
  // UUIDv1 unique to wallet
  uint128 nonce;
  // Public component of ECDSA signing key pair
  address delegatedPublicKey;
  // ECDSA signature of hash by delegate private key
  bytes signature;
}

/**
 * @notice Internally used struct for passing arguments to executeOrderBookTrade without hitting stack limit
 */
struct ExecuteOrderBookTradeArguments {
  // External arguments
  Order buy;
  Order sell;
  OrderBookTrade orderBookTrade;
  IndexPrice[] buyWalletIndexPrices;
  IndexPrice[] sellWalletIndexPrices;
  // Exchange state
  uint64 delegateKeyExpirationPeriodInMs;
  address exitFundWallet;
  address feeWallet;
  address insuranceFundWallet;
  address[] indexPriceCollectionServiceWallets;
}

/**
 * @notice Internally used struct for storing funding multipliers
 */
struct FundingMultiplierQuartet {
  int64 fundingMultiplier0;
  int64 fundingMultiplier1;
  int64 fundingMultiplier2;
  int64 fundingMultiplier3;
}

/**
 * @notice Argument type for `Exchange.addMarket` and `Exchange.setMarketOverrides`
 */
struct Market {
  // Flag to distinguish from empty struct
  bool exists;
  // Flag must be asserted to allow any actions other than deactivation liquidation
  bool isActive;
  // No need to specify quote asset - it is always the same as the quote asset
  string baseAssetSymbol;
  // Chainlink price feed aggregator contract to use for on-chain exit withdrawals
  IChainlinkAggregator chainlinkPriceFeedAddress;
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
  // The min position size in base token
  uint64 minimumPositionSizeInPips;
  // The timestamp of the latest index price provided for this market
  uint64 lastIndexPriceTimestampInMs;
  // Set when deactivating a market to determine price for all position liquidations in that market
  uint64 indexPriceInPipsAtDeactivation;
}

/**
 * @notice Index price data signed by index wallet
 */
struct IndexPrice {
  string baseAssetSymbol;
  // Milliseconds since epoch
  uint64 timestampInMs;
  // Price of base asset in decimal pips * 10^8 in quote terms
  uint64 price;
  // Signature from index price collection service wallet
  bytes signature;
}

/**
 * @notice Argument type for `Exchange.executeOrderBookTrade` and `Hashing.getOrderWalletHash`
 */
struct Order {
  // Must equal `Constants.SIGNATURE_HASH_VERSION`
  uint8 signatureHashVersion;
  // UUIDv1 unique to wallet
  uint128 nonce;
  // Custody wallet address that placed order and (if not using delegate wallet) signed hash
  address wallet;
  // Type of order
  OrderType orderType;
  // Order side wallet is on
  OrderSide side;
  // Order quantity in base asset terms
  uint64 quantityInPips;
  // For limit orders, price in decimal pips * 10^8 in quote terms
  uint64 limitPriceInPips;
  // For stop orders, stop loss or take profit price in decimal pips * 10^8 in quote terms
  uint64 triggerPriceInPips;
  // Type of trigger condition
  OrderTriggerType triggerType;
  // Percentage of price movement in opposite direction before triggering trailing stop
  uint64 callbackRateInPips;
  // Public ID of a separate order that must be filled before this stop order becomes active
  uint128 conditionalOrderId;
  // If true, order execution must move wallet position size towards zero
  bool isReduceOnly;
  // TIF option specified by wallet for order
  OrderTimeInForce timeInForce;
  // STP behavior specified by wallet for order
  OrderSelfTradePrevention selfTradePrevention;
  // Asserted when signed by delegated key instead of custody wallet
  bool isSignedByDelegatedKey;
  // If non-zero, an authorization for a delegate key signer authorized by the custody wallet
  DelegatedKeyAuthorization delegatedKeyAuthorization;
  // Optional custom client order ID
  string clientOrderId;
  // The ECDSA signature of the order hash as produced by Hashing.getOrderWalletHash
  bytes walletSignature;
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
  address payable wallet;
  // Withdrawal quantity
  uint64 grossQuantityInPips;
  // Gas fee deducted from withdrawn quantity to cover dispatcher tx costs
  uint64 gasFeeInPips;
  // The ECDSA signature of the withdrawal hash as produced by Hashing.getWithdrawalWalletHash
  bytes walletSignature;
}
