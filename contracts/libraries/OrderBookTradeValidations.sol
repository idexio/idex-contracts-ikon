// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.15;

import { Constants } from './Constants.sol';
import { Hashing } from './Hashing.sol';
import { OrderSide } from './Enums.sol';
import { Math } from './Math.sol';
import { OrderType } from './Enums.sol';
import { String } from './String.sol';
import { UUID } from './UUID.sol';
import { Validations } from './Validations.sol';
import { Market, Order, OrderBookTrade, NonceInvalidation } from './Structs.sol';

library OrderBookTradeValidations {
  function validateOrderBookTrade(
    Order memory buy,
    Order memory sell,
    OrderBookTrade memory trade,
    string memory collateralAssetSymbol,
    uint64 delegateKeyExpirationPeriodInMs,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => NonceInvalidation) storage nonceInvalidations
  ) internal view returns (bytes32, bytes32) {
    require(
      buy.walletAddress != sell.walletAddress,
      'Self-trading not allowed'
    );

    // Order book trade validations
    validateAssetPair(trade, collateralAssetSymbol, marketsByBaseAssetSymbol);
    validateLimitPrices(buy, sell, trade);
    validateOrderNonces(
      buy,
      sell,
      delegateKeyExpirationPeriodInMs,
      nonceInvalidations
    );
    (bytes32 buyHash, bytes32 sellHash) = validateOrderSignatures(
      buy,
      sell,
      trade
    );
    validateFees(trade);

    return (buyHash, sellHash);
  }

  function validateAssetPair(
    OrderBookTrade memory trade,
    string memory collateralAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view {
    require(
      !String.isEqual(trade.baseAssetSymbol, trade.quoteAssetSymbol),
      'Trade assets must be different'
    );

    require(
      String.isEqual(trade.quoteAssetSymbol, collateralAssetSymbol),
      'Quote and collateral symbol mismatch'
    );

    require(
      marketsByBaseAssetSymbol[trade.baseAssetSymbol].exists,
      'Invalid base asset symbol'
    );
  }

  function validateLimitPrices(
    Order memory buy,
    Order memory sell,
    OrderBookTrade memory trade
  ) internal pure {
    require(
      trade.baseQuantityInPips > 0,
      'Base quantity must be greater than zero'
    );
    require(
      trade.quoteQuantityInPips > 0,
      'Quote quantity must be greater than zero'
    );

    if (isLimitOrderType(buy.orderType)) {
      require(
        calculateImpliedQuoteQuantityInPips(
          trade.baseQuantityInPips,
          buy.limitPriceInPips
        ) >= trade.quoteQuantityInPips,
        'Buy order limit price exceeded'
      );
    }

    if (isLimitOrderType(sell.orderType)) {
      require(
        calculateImpliedQuoteQuantityInPips(
          trade.baseQuantityInPips,
          sell.limitPriceInPips
        ) <= trade.quoteQuantityInPips,
        'Sell order limit price exceeded'
      );
    }
  }

  function validateOrderNonces(
    Order memory buy,
    Order memory sell,
    uint64 delegateKeyExpirationPeriodInMs,
    mapping(address => NonceInvalidation) storage nonceInvalidations
  ) internal view {
    validateOrderNonce(
      buy,
      delegateKeyExpirationPeriodInMs,
      nonceInvalidations
    );
    validateOrderNonce(
      sell,
      delegateKeyExpirationPeriodInMs,
      nonceInvalidations
    );
  }

  function validateOrderNonce(
    Order memory order,
    uint64 delegateKeyExpirationPeriodInMs,
    mapping(address => NonceInvalidation) storage nonceInvalidations
  ) internal view {
    uint64 orderTimestampInMs = UUID.getTimestampInMsFromUuidV1(order.nonce);

    uint64 lastInvalidatedTimestamp = loadLastInvalidatedTimestamp(
      order.walletAddress,
      nonceInvalidations
    );
    require(
      orderTimestampInMs > lastInvalidatedTimestamp,
      order.side == OrderSide.Buy
        ? 'Buy order nonce timestamp too low'
        : 'Sell order nonce timestamp too low'
    );

    if (order.isSignedByDelegatedKey) {
      uint64 issuedTimestampInMs = UUID.getTimestampInMsFromUuidV1(
        order.delegatedKeyAuthorization.nonce
      );
      require(
        issuedTimestampInMs > lastInvalidatedTimestamp &&
          issuedTimestampInMs + delegateKeyExpirationPeriodInMs >
          orderTimestampInMs,
        order.side == OrderSide.Buy
          ? 'Buy order delegated key expired'
          : 'Sell order delegated key expired'
      );
    }
  }

  function validateOrderSignatures(
    Order memory buy,
    Order memory sell,
    OrderBookTrade memory trade
  ) internal pure returns (bytes32, bytes32) {
    bytes32 buyOrderHash = validateOrderSignature(
      buy,
      trade.baseAssetSymbol,
      trade.quoteAssetSymbol
    );
    bytes32 sellOrderHash = validateOrderSignature(
      sell,
      trade.baseAssetSymbol,
      trade.quoteAssetSymbol
    );

    return (buyOrderHash, sellOrderHash);
  }

  function validateOrderSignature(
    Order memory order,
    string memory baseAssetSymbol,
    string memory quoteAssetSymbol
  ) internal pure returns (bytes32) {
    bytes32 orderHash = Hashing.getOrderHash(
      order,
      baseAssetSymbol,
      quoteAssetSymbol
    );

    bool isSignatureValid = order.isSignedByDelegatedKey
      ? (Hashing.isSignatureValid(
        Hashing.getDelegatedKeyHash(
          order.walletAddress,
          order.delegatedKeyAuthorization
        ),
        order.delegatedKeyAuthorization.signature,
        order.walletAddress
      ) &&
        Hashing.isSignatureValid(
          orderHash,
          order.walletSignature,
          order.delegatedKeyAuthorization.delegatedPublicKey
        ))
      : Hashing.isSignatureValid(
        orderHash,
        order.walletSignature,
        order.walletAddress
      );

    require(
      isSignatureValid,
      order.side == OrderSide.Buy
        ? 'Invalid wallet signature for buy order'
        : 'Invalid wallet signature for sell order'
    );

    return orderHash;
  }

  function validateFees(OrderBookTrade memory trade) private pure {
    if (trade.makerFeeQuantityInPips < 0) {
      require(
        Math.abs(trade.makerFeeQuantityInPips) <= trade.takerFeeQuantityInPips,
        'Excessive maker rebate'
      );
    } else {
      require(
        Validations.isFeeQuantityValid(
          uint64(trade.makerFeeQuantityInPips),
          trade.quoteQuantityInPips,
          Constants.maxFeeBasisPoints
        ),
        'Excessive maker fee'
      );
    }

    require(
      Validations.isFeeQuantityValid(
        trade.takerFeeQuantityInPips,
        trade.quoteQuantityInPips,
        Constants.maxFeeBasisPoints
      ),
      'Excessive taker fee'
    );
  }

  function loadLastInvalidatedTimestamp(
    address walletAddress,
    mapping(address => NonceInvalidation) storage nonceInvalidations
  ) private view returns (uint64) {
    if (
      nonceInvalidations[walletAddress].exists &&
      nonceInvalidations[walletAddress].effectiveBlockNumber <= block.number
    ) {
      return nonceInvalidations[walletAddress].timestampInMs;
    }

    return 0;
  }

  function calculateImpliedQuoteQuantityInPips(
    uint64 baseQuantityInPips,
    uint64 limitPriceInPips
  ) private pure returns (uint64) {
    return
      Math.multiplyPipsByFraction(
        baseQuantityInPips,
        limitPriceInPips,
        Constants.pipPriceMultiplier
      );
  }

  function isLimitOrderType(OrderType orderType) internal pure returns (bool) {
    return
      orderType == OrderType.Limit ||
      orderType == OrderType.LimitMaker ||
      orderType == OrderType.StopLossLimit ||
      orderType == OrderType.TakeProfitLimit;
  }
}
