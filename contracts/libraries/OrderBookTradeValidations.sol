// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { Constants } from './Constants.sol';
import { Hashing } from './Hashing.sol';
import { OrderSide } from './Enums.sol';
import { Math } from './Math.sol';
import { OrderType } from './Enums.sol';
import { String } from './String.sol';
import { UUID } from './UUID.sol';
import { Validations } from './Validations.sol';
import { ExecuteOrderBookTradeArguments, Market, Order, OrderBookTrade, NonceInvalidation } from './Structs.sol';

library OrderBookTradeValidations {
  function validateOrderBookTrade(
    ExecuteOrderBookTradeArguments memory arguments,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => NonceInvalidation) storage nonceInvalidations
  )
    internal
    view
    returns (
      bytes32 buyHash,
      bytes32 sellHash,
      Market memory market
    )
  {
    require(
      arguments.buy.wallet != arguments.sell.wallet,
      'Self-trading not allowed'
    );

    // Order book trade validations
    market = validateAssetPair(
      arguments.orderBookTrade,
      arguments.quoteAssetSymbol,
      marketsByBaseAssetSymbol
    );
    validateLimitPrices(
      arguments.buy,
      arguments.sell,
      arguments.orderBookTrade
    );
    validateOrderNonces(
      arguments.buy,
      arguments.sell,
      arguments.delegateKeyExpirationPeriodInMs,
      nonceInvalidations
    );
    (buyHash, sellHash) = validateOrderSignatures(
      arguments.buy,
      arguments.sell,
      arguments.orderBookTrade
    );
    validateFees(arguments.orderBookTrade);
  }

  function validateAssetPair(
    OrderBookTrade memory trade,
    string memory quoteAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (Market memory market) {
    require(
      !String.isEqual(trade.baseAssetSymbol, trade.quoteAssetSymbol),
      'Trade assets must be different'
    );

    require(
      String.isEqual(trade.quoteAssetSymbol, quoteAssetSymbol),
      'Quote and quote symbol mismatch'
    );

    market = marketsByBaseAssetSymbol[trade.baseAssetSymbol];
    require(market.exists && market.isActive, 'No active market found');
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
      order.wallet,
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
          order.wallet,
          order.delegatedKeyAuthorization
        ),
        order.delegatedKeyAuthorization.signature,
        order.wallet
      ) &&
        Hashing.isSignatureValid(
          orderHash,
          order.walletSignature,
          order.delegatedKeyAuthorization.delegatedPublicKey
        ))
      : Hashing.isSignatureValid(
        orderHash,
        order.walletSignature,
        order.wallet
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
    address wallet,
    mapping(address => NonceInvalidation) storage nonceInvalidations
  ) private view returns (uint64) {
    if (
      nonceInvalidations[wallet].exists &&
      nonceInvalidations[wallet].effectiveBlockNumber <= block.number
    ) {
      return nonceInvalidations[wallet].timestampInMs;
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
      orderType == OrderType.StopLossLimit ||
      orderType == OrderType.TakeProfitLimit;
  }
}
