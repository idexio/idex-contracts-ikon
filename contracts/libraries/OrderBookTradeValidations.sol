// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { Constants } from "./Constants.sol";
import { Hashing } from "./Hashing.sol";
import { Math } from "./Math.sol";
import { NonceInvalidations } from "./NonceInvalidations.sol";
import { String } from "./String.sol";
import { UUID } from "./UUID.sol";
import { Validations } from "./Validations.sol";
import { ExecuteOrderBookTradeArguments, Market, Order, OrderBookTrade, NonceInvalidation } from "./Structs.sol";
import { OrderSide, OrderTimeInForce, OrderTriggerType, OrderType } from "./Enums.sol";

library OrderBookTradeValidations {
  using NonceInvalidations for mapping(address => NonceInvalidation[]);

  function validateOrderBookTrade(
    ExecuteOrderBookTradeArguments memory arguments,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => NonceInvalidation[]) storage nonceInvalidationsByWallet
  ) internal view returns (bytes32 buyHash, bytes32 sellHash, Market memory market) {
    require(arguments.buy.wallet != arguments.sell.wallet, "Self-trading not allowed");

    // Order book trade validations
    market = _validateAssetPair(arguments.orderBookTrade, marketsByBaseAssetSymbol);
    _validateExecutionConditions(
      arguments.buy,
      arguments.sell,
      arguments.orderBookTrade,
      arguments.exitFundWallet,
      arguments.insuranceFundWallet
    );
    _validateNonces(
      arguments.buy,
      arguments.sell,
      arguments.delegateKeyExpirationPeriodInMs,
      nonceInvalidationsByWallet
    );
    (buyHash, sellHash) = _validateSignatures(arguments.buy, arguments.sell, arguments.orderBookTrade);
    _validateFees(arguments.orderBookTrade);
  }

  function _calculateImpliedQuoteQuantity(uint64 baseQuantity, uint64 limitPrice) private pure returns (uint64) {
    return Math.multiplyPipsByFraction(baseQuantity, limitPrice, Constants.PIP_PRICE_MULTIPLIER);
  }

  function _isLimitOrderType(OrderType orderType) private pure returns (bool) {
    return
      orderType == OrderType.Limit || orderType == OrderType.StopLossLimit || orderType == OrderType.TakeProfitLimit;
  }

  function _validateAssetPair(
    OrderBookTrade memory trade,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (Market memory market) {
    require(!String.isEqual(trade.baseAssetSymbol, trade.quoteAssetSymbol), "Trade assets must be different");

    require(String.isEqual(trade.quoteAssetSymbol, Constants.QUOTE_ASSET_SYMBOL), "Quote symbol mismatch");

    market = marketsByBaseAssetSymbol[trade.baseAssetSymbol];
    require(market.exists && market.isActive, "No active market found");
  }

  function _validateFees(OrderBookTrade memory trade) private pure {
    if (trade.makerFeeQuantity < 0) {
      require(Math.abs(trade.makerFeeQuantity) <= trade.takerFeeQuantity, "Excessive maker rebate");
    } else {
      require(
        Validations.isFeeQuantityValid(uint64(trade.makerFeeQuantity), trade.quoteQuantity),
        "Excessive maker fee"
      );
    }

    require(Validations.isFeeQuantityValid(trade.takerFeeQuantity, trade.quoteQuantity), "Excessive taker fee");
  }

  function _validateExecutionConditions(
    Order memory buy,
    Order memory sell,
    OrderBookTrade memory trade,
    address exitFundWallet,
    address insuranceFundWallet
  ) private pure {
    require(trade.baseQuantity > 0, "Base quantity must be greater than zero");
    require(trade.quoteQuantity > 0, "Quote quantity must be greater than zero");

    _validateExecutionConditions(buy, trade, true, exitFundWallet, insuranceFundWallet);
    _validateExecutionConditions(sell, trade, false, exitFundWallet, insuranceFundWallet);
  }

  function _validateExecutionConditions(
    Order memory order,
    OrderBookTrade memory trade,
    bool isBuy,
    address exitFundWallet,
    address insuranceFundWallet
  ) private pure {
    _validateLimitPrice(order, trade, isBuy);
    _validateTimeInForce(order, trade, isBuy);
    _validateTriggerFields(order);

    require(order.wallet != exitFundWallet, "EF cannot trade");

    if (order.wallet == insuranceFundWallet) {
      require(order.isReduceOnly && order.isSignedByDelegatedKey, "IF order must be reduce only and signed by DK");
    }
  }

  function _validateLimitPrice(Order memory order, OrderBookTrade memory trade, bool isBuy) private pure {
    if (_isLimitOrderType(order.orderType)) {
      require(order.limitPrice > 0, "Invalid limit price");

      uint64 impliedQuoteQuantity = _calculateImpliedQuoteQuantity(trade.baseQuantity, order.limitPrice);
      require(
        isBuy ? impliedQuoteQuantity >= trade.quoteQuantity : impliedQuoteQuantity <= trade.quoteQuantity,
        "Order limit price exceeded"
      );
    } else {
      require(order.limitPrice == 0, "Invalid limit price");
    }
  }

  function _validateNonces(
    Order memory buy,
    Order memory sell,
    uint64 delegateKeyExpirationPeriodInMs,
    mapping(address => NonceInvalidation[]) storage nonceInvalidationsByWallet
  ) private view {
    _validateNonce(buy, delegateKeyExpirationPeriodInMs, nonceInvalidationsByWallet);
    _validateNonce(sell, delegateKeyExpirationPeriodInMs, nonceInvalidationsByWallet);
  }

  function _validateNonce(
    Order memory order,
    uint64 delegateKeyExpirationPeriodInMs,
    mapping(address => NonceInvalidation[]) storage nonceInvalidationsByWallet
  ) private view {
    uint64 orderTimestampInMs = UUID.getTimestampInMsFromUuidV1(order.nonce);

    uint64 lastInvalidatedTimestamp = nonceInvalidationsByWallet.loadLastInvalidatedTimestamp(order.wallet);
    require(
      orderTimestampInMs > lastInvalidatedTimestamp,
      order.side == OrderSide.Buy ? "Buy order nonce timestamp too low" : "Sell order nonce timestamp too low"
    );

    if (order.isSignedByDelegatedKey) {
      uint64 issuedTimestampInMs = UUID.getTimestampInMsFromUuidV1(order.delegatedKeyAuthorization.nonce);
      require(
        issuedTimestampInMs > lastInvalidatedTimestamp,
        order.side == OrderSide.Buy ? "Buy order delegated key invalidated" : "Sell order delegated key invalidated"
      );
      require(
        issuedTimestampInMs + delegateKeyExpirationPeriodInMs > orderTimestampInMs,
        order.side == OrderSide.Buy ? "Buy order delegated key expired" : "Sell order delegated key expired"
      );
      require(
        orderTimestampInMs > issuedTimestampInMs,
        order.side == OrderSide.Buy ? "Buy order predates delegated key" : "Sell order predates delegated key"
      );
    }
  }

  function _validateSignatures(
    Order memory buy,
    Order memory sell,
    OrderBookTrade memory trade
  ) private pure returns (bytes32, bytes32) {
    bytes32 buyOrderHash = _validateSignature(buy, trade.baseAssetSymbol, trade.quoteAssetSymbol);
    bytes32 sellOrderHash = _validateSignature(sell, trade.baseAssetSymbol, trade.quoteAssetSymbol);

    return (buyOrderHash, sellOrderHash);
  }

  function _validateSignature(
    Order memory order,
    string memory baseAssetSymbol,
    string memory quoteAssetSymbol
  ) private pure returns (bytes32) {
    bytes32 orderHash = Hashing.getOrderHash(order, baseAssetSymbol, quoteAssetSymbol);

    bool isSignatureValid = order.isSignedByDelegatedKey
      ? (Hashing.isSignatureValid(
        Hashing.getDelegatedKeyMessage(order.delegatedKeyAuthorization),
        order.delegatedKeyAuthorization.signature,
        order.wallet
      ) &&
        Hashing.isSignatureValid(orderHash, order.walletSignature, order.delegatedKeyAuthorization.delegatedPublicKey))
      : Hashing.isSignatureValid(orderHash, order.walletSignature, order.wallet);

    require(
      isSignatureValid,
      order.side == OrderSide.Buy ? "Invalid wallet signature for buy order" : "Invalid wallet signature for sell order"
    );

    return orderHash;
  }

  function _validateTimeInForce(Order memory order, OrderBookTrade memory trade, bool isBuy) private pure {
    if (order.timeInForce == OrderTimeInForce.gtx) {
      require(
        _isLimitOrderType(order.orderType) && trade.makerSide == (isBuy ? OrderSide.Buy : OrderSide.Sell),
        "gtx order must be limit maker"
      );
    } else if (order.timeInForce == OrderTimeInForce.ioc) {
      require(trade.makerSide == (isBuy ? OrderSide.Sell : OrderSide.Buy), "ioc order must be taker");
    } else if (order.timeInForce == OrderTimeInForce.fok) {
      require(trade.makerSide == (isBuy ? OrderSide.Sell : OrderSide.Buy), "fok order must be taker");
    }
  }

  function _validateTriggerFields(Order memory order) private pure {
    if (
      order.orderType == OrderType.StopLossMarket ||
      order.orderType == OrderType.StopLossLimit ||
      order.orderType == OrderType.TakeProfitMarket ||
      order.orderType == OrderType.TakeProfitLimit
    ) {
      require(order.triggerPrice > 0, "Missing trigger price");
    } else if (order.orderType != OrderType.TrailingStop) {
      require(order.triggerPrice == 0, "Invalid trigger price");
    }

    require(
      order.orderType == OrderType.TrailingStop ? order.callbackRate > 0 : order.callbackRate == 0,
      "Invalid callback rate"
    );

    require(
      order.triggerPrice == 0 ? order.triggerType == OrderTriggerType.None : order.triggerType != OrderTriggerType.None,
      "Invalid trigger type"
    );
  }
}
