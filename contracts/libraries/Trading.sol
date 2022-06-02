// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.13;

import { BalanceTracking } from './BalanceTracking.sol';
import { OrderBookTradeValidations } from './OrderBookTradeValidations.sol';
import { OrderSide, OrderType } from './Enums.sol';
import { Perpetual } from './Perpetual.sol';
import { Market, OraclePrice, Order, OrderBookTrade, NonceInvalidation } from './Structs.sol';

library Trading {
  using BalanceTracking for BalanceTracking.Storage;

  struct ExecuteOrderBookTradeArguments {
    // External arguments
    Order buy;
    Order sell;
    OrderBookTrade orderBookTrade;
    OraclePrice[] oraclePrices;
    // Exchange state
    uint8 collateralAssetDecimals;
    string collateralAssetSymbol;
    uint64 delegateKeyExpirationPeriodInMs;
    address feeWallet;
    address oracleWalletAddress;
  }

  function executeOrderBookTrade(
    ExecuteOrderBookTradeArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(bytes32 => bool) storage completedOrderHashes,
    mapping(string => int64[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    Market[] storage markets,
    mapping(string => Market) storage marketsBySymbol,
    mapping(address => NonceInvalidation) storage nonceInvalidations,
    mapping(bytes32 => uint64) storage partiallyFilledOrderQuantitiesInPips
  ) public {
    (bytes32 buyHash, bytes32 sellHash) = OrderBookTradeValidations
      .validateOrderBookTrade(
        arguments.buy,
        arguments.sell,
        arguments.orderBookTrade,
        arguments.collateralAssetSymbol,
        arguments.delegateKeyExpirationPeriodInMs,
        marketsBySymbol,
        nonceInvalidations
      );

    updateOrderFilledQuantities(
      arguments.buy,
      buyHash,
      arguments.sell,
      sellHash,
      arguments.orderBookTrade,
      completedOrderHashes,
      partiallyFilledOrderQuantitiesInPips
    );

    // Funding payments must be made prior to updating any position to ensure that the funding is calculated
    // against the position size at the time of each historic multipler
    Perpetual.updateWalletsFunding(
      arguments.buy.walletAddress,
      arguments.sell.walletAddress,
      arguments.collateralAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      markets
    );

    balanceTracking.updateForOrderBookTrade(
      arguments.buy,
      arguments.sell,
      arguments.orderBookTrade,
      arguments.feeWallet
    );

    validateInitialMarginRequirements(arguments, balanceTracking, markets);
  }

  function updateOrderFilledQuantities(
    Order memory buy,
    bytes32 buyHash,
    Order memory sell,
    bytes32 sellHash,
    OrderBookTrade memory orderBookTrade,
    mapping(bytes32 => bool) storage completedOrderHashes,
    mapping(bytes32 => uint64) storage partiallyFilledOrderQuantitiesInPips
  ) private {
    // Buy side
    updateOrderFilledQuantity(
      buy,
      buyHash,
      orderBookTrade.baseQuantityInPips,
      orderBookTrade.quoteQuantityInPips,
      completedOrderHashes,
      partiallyFilledOrderQuantitiesInPips
    );
    // Sell side
    updateOrderFilledQuantity(
      sell,
      sellHash,
      orderBookTrade.baseQuantityInPips,
      orderBookTrade.quoteQuantityInPips,
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

  function validateInitialMarginRequirements(
    ExecuteOrderBookTradeArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    Market[] storage markets
  ) private view {
    require(
      Perpetual.isInitialMarginRequirementMet(
        arguments.buy.walletAddress,
        arguments.oraclePrices,
        arguments.collateralAssetDecimals,
        arguments.collateralAssetSymbol,
        arguments.oracleWalletAddress,
        balanceTracking,
        markets
      ),
      'Initial margin requirement not met for buy wallet'
    );
    require(
      Perpetual.isInitialMarginRequirementMet(
        arguments.sell.walletAddress,
        arguments.oraclePrices,
        arguments.collateralAssetDecimals,
        arguments.collateralAssetSymbol,
        arguments.oracleWalletAddress,
        balanceTracking,
        markets
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
