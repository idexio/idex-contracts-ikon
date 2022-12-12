// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Funding } from "./Funding.sol";
import { MutatingMargin } from "./MutatingMargin.sol";
import { NonMutatingMargin } from "./NonMutatingMargin.sol";
import { OrderBookTradeValidations } from "./OrderBookTradeValidations.sol";
import { OrderSide, OrderType } from "./Enums.sol";
import { ExecuteOrderBookTradeArguments, FundingMultiplierQuartet, Market, MarketOverrides, IndexPrice, Order, OrderBookTrade, NonceInvalidation } from "./Structs.sol";

library Trading {
  using BalanceTracking for BalanceTracking.Storage;

  // solhint-disable-next-line func-name-mixedcase
  function executeOrderBookTrade_delegatecall(
    ExecuteOrderBookTradeArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(bytes32 => bool) storage completedOrderHashes,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => NonceInvalidation[]) storage nonceInvalidationsByWallet,
    mapping(bytes32 => uint64) storage partiallyFilledOrderQuantities
  ) public {
    (bytes32 buyHash, bytes32 sellHash, Market memory market) = OrderBookTradeValidations.validateOrderBookTrade(
      arguments,
      marketsByBaseAssetSymbol,
      nonceInvalidationsByWallet
    );

    _updateOrderFilledQuantities(arguments, buyHash, sellHash, completedOrderHashes, partiallyFilledOrderQuantities);

    // Funding payments must be made prior to updating any position to ensure that the funding is calculated
    // against the position size at the time of each historic multipler
    Funding.updateWalletFunding(
      arguments.buy.wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.updateWalletFunding(
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
    mapping(bytes32 => uint64) storage partiallyFilledOrderQuantities
  ) private {
    // Buy side
    _updateOrderFilledQuantity(
      arguments.buy,
      buyHash,
      arguments.orderBookTrade.baseQuantity,
      completedOrderHashes,
      partiallyFilledOrderQuantities
    );
    // Sell side
    _updateOrderFilledQuantity(
      arguments.sell,
      sellHash,
      arguments.orderBookTrade.baseQuantity,
      completedOrderHashes,
      partiallyFilledOrderQuantities
    );
  }

  // Update filled quantities tracking for order to prevent over- or double-filling orders
  function _updateOrderFilledQuantity(
    Order memory order,
    bytes32 orderHash,
    uint64 grossBaseQuantity,
    mapping(bytes32 => bool) storage completedOrderHashes,
    mapping(bytes32 => uint64) storage partiallyFilledOrderQuantities
  ) private {
    require(!completedOrderHashes[orderHash], "Order double filled");

    // Total quantity of above filled as a result of all trade executions, including this one
    uint64 newFilledQuantity;

    // Ttrack partially filled quantities in base terms
    newFilledQuantity = grossBaseQuantity + partiallyFilledOrderQuantities[orderHash];

    uint64 quantity = order.quantity;
    require(newFilledQuantity <= quantity, "Order overfilled");
    if (newFilledQuantity < quantity) {
      // If the order was partially filled, track the new filled quantity
      partiallyFilledOrderQuantities[orderHash] = newFilledQuantity;
    } else {
      // If the order was completed, delete any partial fill tracking and instead track its completion
      // to prevent future double fills
      delete partiallyFilledOrderQuantities[orderHash];
      completedOrderHashes[orderHash] = true;
    }
  }

  function _validateInitialMarginRequirementsAndUpdateLastIndexPrice(
    ExecuteOrderBookTradeArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    require(
      MutatingMargin.isInitialMarginRequirementMetAndUpdateLastIndexPrice(
        NonMutatingMargin.LoadArguments(
          arguments.buy.wallet,
          arguments.buyWalletIndexPrices,
          arguments.indexPriceCollectionServiceWallets
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      ),
      "Initial margin requirement not met for buy wallet"
    );
    require(
      MutatingMargin.isInitialMarginRequirementMetAndUpdateLastIndexPrice(
        NonMutatingMargin.LoadArguments(
          arguments.sell.wallet,
          arguments.sellWalletIndexPrices,
          arguments.indexPriceCollectionServiceWallets
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      ),
      "Initial margin requirement not met for sell wallet"
    );
  }
}
