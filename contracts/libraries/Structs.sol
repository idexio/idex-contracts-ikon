// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { AggregatorV3Interface as IChainlinkAggregator } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import { OrderSelfTradePrevention, OrderSide, OrderTimeInForce, OrderTriggerType, OrderType } from "./Enums.sol";

// This file contains definitions for externally-facing structs used as argument or return types for Exchange functions

/**
 * @notice Argument type for `Exchange.deleverageInMaintenanceAcquisition` and `Exchange.deleverageExitAcquisition`
 */
struct AcquisitionDeleverageArguments {
  string baseAssetSymbol;
  address deleveragingWallet;
  address liquidatingWallet;
  // Liquidation quote quantities for union of liquidating and IF wallet positions
  uint64[] validateInsuranceFundCannotLiquidateWalletQuoteQuantities;
  // Base quantity to decrease position being liquidated
  uint64 liquidationBaseQuantity;
  // Quote quantity for the position being liquidated
  uint64 liquidationQuoteQuantity;
  // Index prices for deleveraging wallet after acquiring liquidating positions
  IndexPrice[] deleveragingWalletIndexPrices;
  // Index prices for union of liquidating and IF wallet position
  IndexPrice[] validateInsuranceFundCannotLiquidateWalletIndexPrices;
  // Index prices for liquidating wallet before liquidation
  IndexPrice[] liquidatingWalletIndexPrices;
}

/**
 * @notice Internally used struct for tracking wallet balances and funding updates
 */
struct Balance {
  bool isMigrated;
  int64 balance;
  // The last funding update timestamp and cost basis are only relevant for base asset positions
  uint64 lastUpdateTimestampInMs;
  int64 costBasis;
}

/**
 * @notice Argument type for `Exchange.deleverageInsuranceFundClosure` and `Exchange.deleverageExitFundClosure`
 */
struct ClosureDeleverageArguments {
  string baseAssetSymbol;
  address deleveragingWallet;
  // IF or EF depending on delerageType
  address liquidatingWallet;
  // Base quantity to decrease position being liquidated
  uint64 liquidationBaseQuantity;
  // Quote quantity for the position being liquidated
  uint64 liquidationQuoteQuantity;
  // Index prices for liquidating wallet before liquidation
  IndexPrice[] liquidatingWalletIndexPrices;
  // Index prices for deleveraging wallet after acquiring liquidated positions
  IndexPrice[] deleveragingWalletIndexPrices;
}

/**
 * @notice Field in `Order` struct for optionally authorizing a delegate key signing wallet
 */
struct DelegatedKeyAuthorization {
  // UUIDv1 unique to wallet
  uint128 nonce;
  // Public component of ECDSA signing key pair
  address delegatedPublicKey;
  // ECDSA signature of hash by issuing custody wallet private key
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
  // The timestamp of the latest index price provided for this market
  uint64 lastIndexPriceTimestampInMs;
  // Set when deactivating a market to determine price for all position liquidations in that market
  uint64 indexPriceAtDeactivation;
  // Fields that can be overriden per wallet
  OverridableMarketFields overridableFields;
}

/**
 * @notice Argument type for `Exchange.setMarketOverrides`
 */
struct OverridableMarketFields {
  // The margin fraction needed to open a position
  uint64 initialMarginFraction;
  // The margin fraction required to prevent liquidation
  uint64 maintenanceMarginFraction;
  // The increase of initialMarginFraction for each incrementalPositionSize above the
  // baselinePositionSize
  uint64 incrementalInitialMarginFraction;
  // The max position size in base token before increasing the initial-margin-fraction.
  uint64 baselinePositionSize;
  // The step size (in base token) for increasing the initialMarginFraction by
  // (incrementalInitialMarginFraction per step)
  uint64 incrementalPositionSize;
  // The max position size in base token
  uint64 maximumPositionSize;
  // The min position size in base token
  uint64 minimumPositionSize;
}

/**
 * @notice Internally used struct to track market overrides per wallet
 */
struct MarketOverrides {
  // Flag to distinguish from empty struct
  bool exists;
  // Market fields that can be overriden per wallet
  OverridableMarketFields overridableFields;
}

/**
 * @notice Internally used struct capturing wallet order nonce invalidations created via `invalidateOrderNonce`
 */
struct NonceInvalidation {
  uint64 timestampInMs;
  uint256 effectiveBlockNumber;
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
  uint64 quantity;
  // For limit orders, price in decimal pips * 10^8 in quote terms
  uint64 limitPrice;
  // For stop orders, stop loss or take profit price in decimal pips * 10^8 in quote terms
  uint64 triggerPrice;
  // Type of trigger condition
  OrderTriggerType triggerType;
  // Percentage of price movement in opposite direction before triggering trailing stop
  uint64 callbackRate;
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
  uint64 baseQuantity;
  // Amount of quote asset executed
  uint64 quoteQuantity;
  // Fee paid by (or, if negative, rebated to) liquidity maker in quote (collateral) asset
  int64 makerFeeQuantity;
  // Fee paid by liquidity taker in quote (collateral) asset
  uint64 takerFeeQuantity;
  // Execution price of trade in decimal pips * 10^8 in quote terms
  uint64 price;
  // Which side of the order (buy or sell) the liquidity maker was on
  OrderSide makerSide;
}

/**
 * @notice Argument type for `Exchange.liquidateWalletInMaintenance`,
 * `Exchange.liquidateWalletInMaintenanceDuringSystemRecovery`, and `Exchange.liquidateWalletExited`
 */
struct WalletLiquidationArguments {
  address counterpartyWallet; // Insurance Fund or Exit Fund
  IndexPrice[] counterpartyWalletIndexPrices; // After acquiring liquidated positions
  address liquidatingWallet;
  IndexPrice[] liquidatingWalletIndexPrices;
  uint64[] liquidationQuoteQuantities;
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
  uint64 grossQuantity;
  // Gas fee deducted from withdrawn quantity to cover dispatcher tx costs
  uint64 gasFee;
  // The ECDSA signature of the withdrawal hash as produced by Hashing.getWithdrawalWalletHash
  bytes walletSignature;
}
