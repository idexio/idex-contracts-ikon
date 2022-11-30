// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Funding } from "./Funding.sol";
import { Margin } from "./Margin.sol";
import { OrderBookTradeValidations } from "./OrderBookTradeValidations.sol";
import { OrderSide, OrderType } from "./Enums.sol";
import { ExecuteOrderBookTradeArguments, FundingMultiplierQuartet, Market, IndexPrice, Order, OrderBookTrade, NonceInvalidation } from "./Structs.sol";

library Trading {
  using BalanceTracking for BalanceTracking.Storage;

  function executeOrderBookTrade(
    ExecuteOrderBookTradeArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(bytes32 => bool) storage completedOrderHashes,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => NonceInvalidation) storage nonceInvalidations,
    mapping(bytes32 => uint64) storage partiallyFilledOrderQuantitiesInPips
  ) public {
    (bytes32 buyHash, bytes32 sellHash, Market memory market) = OrderBookTradeValidations.validateOrderBookTrade(
      arguments,
      marketsByBaseAssetSymbol,
      nonceInvalidations
    );

    _updateOrderFilledQuantities(
      arguments,
      buyHash,
      sellHash,
      completedOrderHashes,
      partiallyFilledOrderQuantitiesInPips
    );

    // Funding payments must be made prior to updating any position to ensure that the funding is calculated
    // against the position size at the time of each historic multipler
    Funding.updateWalletFundingInternal(
      arguments.buy.wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.updateWalletFundingInternal(
      arguments.sell.wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    balanceTracking.updateForOrderBookTrade(
      arguments,
      market,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    _validateInitialMarginRequirementsAndUpdateLastIndexPrice(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _updateOrderFilledQuantities(
    ExecuteOrderBookTradeArguments memory arguments,
    bytes32 buyHash,
    bytes32 sellHash,
    mapping(bytes32 => bool) storage completedOrderHashes,
    mapping(bytes32 => uint64) storage partiallyFilledOrderQuantitiesInPips
  ) private {
    // Buy side
    _updateOrderFilledQuantity(
      arguments.buy,
      buyHash,
      arguments.orderBookTrade.baseQuantityInPips,
      completedOrderHashes,
      partiallyFilledOrderQuantitiesInPips
    );
    // Sell side
    _updateOrderFilledQuantity(
      arguments.sell,
      sellHash,
      arguments.orderBookTrade.baseQuantityInPips,
      completedOrderHashes,
      partiallyFilledOrderQuantitiesInPips
    );
  }

  // Update filled quantities tracking for order to prevent over- or double-filling orders
  function _updateOrderFilledQuantity(
    Order memory order,
    bytes32 orderHash,
    uint64 grossBaseQuantityInPips,
    mapping(bytes32 => bool) storage completedOrderHashes,
    mapping(bytes32 => uint64) storage partiallyFilledOrderQuantitiesInPips
  ) private {
    require(!completedOrderHashes[orderHash], "Order double filled");

    // Total quantity of above filled as a result of all trade executions, including this one
    uint64 newFilledQuantityInPips;

    // Ttrack partially filled quantities in base terms
    newFilledQuantityInPips = grossBaseQuantityInPips + partiallyFilledOrderQuantitiesInPips[orderHash];

    uint64 quantityInPips = order.quantityInPips;
    require(newFilledQuantityInPips <= quantityInPips, "Order overfilled");
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

  function _validateInitialMarginRequirementsAndUpdateLastIndexPrice(
    ExecuteOrderBookTradeArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    require(
      Margin.isInitialMarginRequirementMetAndUpdateLastIndexPrice(
        Margin.LoadArguments(arguments.buy.wallet, arguments.buyIndexPrices, arguments.indexWallet),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      ),
      "Initial margin requirement not met for buy wallet"
    );
    require(
      Margin.isInitialMarginRequirementMetAndUpdateLastIndexPrice(
        Margin.LoadArguments(arguments.sell.wallet, arguments.sellIndexPrices, arguments.indexWallet),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      ),
      "Initial margin requirement not met for sell wallet"
    );
  }
}
