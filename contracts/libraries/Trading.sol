// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.15;

import { BalanceTracking } from './BalanceTracking.sol';
import { Funding } from './Funding.sol';
import { Margin } from './Margin.sol';
import { OrderBookTradeValidations } from './OrderBookTradeValidations.sol';
import { Perpetual } from './Perpetual.sol';
import { OrderSide, OrderType } from './Enums.sol';
import { ExecuteOrderBookTradeArguments, FundingMultiplierQuartet, Market, OraclePrice, Order, OrderBookTrade, NonceInvalidation } from './Structs.sol';

library Trading {
  using BalanceTracking for BalanceTracking.Storage;

  function executeOrderBookTrade(
    ExecuteOrderBookTradeArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(bytes32 => bool) storage completedOrderHashes,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(address => NonceInvalidation) storage nonceInvalidations,
    mapping(bytes32 => uint64) storage partiallyFilledOrderQuantitiesInPips
  ) public {
    (
      bytes32 buyHash,
      bytes32 sellHash,
      Market memory market
    ) = OrderBookTradeValidations.validateOrderBookTrade(
        arguments,
        marketsByBaseAssetSymbol,
        nonceInvalidations
      );

    updateOrderFilledQuantities(
      arguments,
      buyHash,
      sellHash,
      completedOrderHashes,
      partiallyFilledOrderQuantitiesInPips
    );

    // Funding payments must be made prior to updating any position to ensure that the funding is calculated
    // against the position size at the time of each historic multipler
    Funding.updateWalletFunding(
      arguments.buy.walletAddress,
      arguments.quoteAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol,
      baseAssetSymbolsWithOpenPositionsByWallet
    );
    Funding.updateWalletFunding(
      arguments.sell.walletAddress,
      arguments.quoteAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    balanceTracking.updateForOrderBookTrade(
      arguments,
      market,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    validateInitialMarginRequirementsAndUpdateLastOraclePrice(
      arguments,
      balanceTracking,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol,
      baseAssetSymbolsWithOpenPositionsByWallet
    );
  }

  function updateOrderFilledQuantities(
    ExecuteOrderBookTradeArguments memory arguments,
    bytes32 buyHash,
    bytes32 sellHash,
    mapping(bytes32 => bool) storage completedOrderHashes,
    mapping(bytes32 => uint64) storage partiallyFilledOrderQuantitiesInPips
  ) private {
    // Buy side
    updateOrderFilledQuantity(
      arguments.buy,
      buyHash,
      arguments.orderBookTrade.baseQuantityInPips,
      arguments.orderBookTrade.quoteQuantityInPips,
      completedOrderHashes,
      partiallyFilledOrderQuantitiesInPips
    );
    // Sell side
    updateOrderFilledQuantity(
      arguments.sell,
      sellHash,
      arguments.orderBookTrade.baseQuantityInPips,
      arguments.orderBookTrade.quoteQuantityInPips,
      completedOrderHashes,
      partiallyFilledOrderQuantitiesInPips
    );
  }

  // Update filled quantities tracking for order to prevent over- or double-filling orders
  function updateOrderFilledQuantity(
    Order memory order,
    bytes32 orderHash,
    uint64 grossBaseQuantityInPips,
    uint64 grossQuoteQuantityInPips,
    mapping(bytes32 => bool) storage completedOrderHashes,
    mapping(bytes32 => uint64) storage partiallyFilledOrderQuantitiesInPips
  ) private {
    require(!completedOrderHashes[orderHash], 'Order double filled');

    // Total quantity of above filled as a result of all trade executions, including this one
    uint64 newFilledQuantityInPips;

    // Market orders can express quantity in quote terms, and can be partially filled by multiple
    // limit maker orders necessitating tracking partially filled amounts in quote terms to
    // determine completion
    if (order.isQuantityInQuote) {
      require(
        isMarketOrderType(order.orderType),
        'Order quote quantity only valid for market orders'
      );
      newFilledQuantityInPips =
        grossQuoteQuantityInPips +
        partiallyFilledOrderQuantitiesInPips[orderHash];
    } else {
      // All other orders track partially filled quantities in base terms
      newFilledQuantityInPips =
        grossBaseQuantityInPips +
        partiallyFilledOrderQuantitiesInPips[orderHash];
    }

    uint64 quantityInPips = order.quantityInPips;
    require(newFilledQuantityInPips <= quantityInPips, 'Order overfilled');
    if (newFilledQuantityInPips < quantityInPips) {
      // If the order was partially filled, track the new filled quantity
      partiallyFilledOrderQuantitiesInPips[orderHash] = newFilledQuantityInPips;
    } else {
      // If the order was completed, delete any partial fill tracking and instead track its completion
      // to prevent future double fills
      delete partiallyFilledOrderQuantitiesInPips[orderHash];
      completedOrderHashes[orderHash] = true;
    }
  }

  function validateInitialMarginRequirementsAndUpdateLastOraclePrice(
    ExecuteOrderBookTradeArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet
  ) private {
    require(
      Margin.isInitialMarginRequirementMetAndUpdateLastOraclePrice(
        Margin.LoadArguments(
          arguments.buy.walletAddress,
          arguments.buyOraclePrices,
          arguments.oracleWalletAddress,
          arguments.quoteAssetDecimals,
          arguments.quoteAssetSymbol
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
      ),
      'Initial margin requirement not met for buy wallet'
    );
    require(
      Margin.isInitialMarginRequirementMetAndUpdateLastOraclePrice(
        Margin.LoadArguments(
          arguments.sell.walletAddress,
          arguments.sellOraclePrices,
          arguments.oracleWalletAddress,
          arguments.quoteAssetDecimals,
          arguments.quoteAssetSymbol
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
      ),
      'Initial margin requirement not met for sell wallet'
    );
  }

  function isMarketOrderType(OrderType orderType) private pure returns (bool) {
    return
      orderType == OrderType.Market ||
      orderType == OrderType.StopLoss ||
      orderType == OrderType.TakeProfit;
  }
}
