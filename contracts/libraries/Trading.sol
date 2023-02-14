// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Exiting } from "./Exiting.sol";
import { Funding } from "./Funding.sol";
import { Margin } from "./Margin.sol";
import { OrderBookTradeValidations } from "./OrderBookTradeValidations.sol";
import { ExecuteOrderBookTradeArguments, FundingMultiplierQuartet, Market, MarketOverrides, Order, NonceInvalidation } from "./Structs.sol";

library Trading {
  using BalanceTracking for BalanceTracking.Storage;

  struct Arguments {
    ExecuteOrderBookTradeArguments externalArguments;
    // Exchange state
    uint64 delegateKeyExpirationPeriodInMs;
    address exitFundWallet;
    address feeWallet;
    address insuranceFundWallet;
    // Though unclear why, adding this unused bytes field at the end of the struct avoilds a stack too deep error in
    // executeOrderBookTrade_delegatecall
    // solhint-disable-next-line var-name-mixedcase
    bytes __;
  }

  // solhint-disable-next-line func-name-mixedcase
  function executeOrderBookTrade_delegatecall(
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(bytes32 => bool) storage completedOrderHashes,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => NonceInvalidation[]) storage nonceInvalidationsByWallet,
    mapping(bytes32 => uint64) storage partiallyFilledOrderQuantities,
    mapping(address => Exiting.WalletExit) storage walletExits
  ) public {
    require(
      !Exiting.isWalletExitFinalized(arguments.externalArguments.buy.wallet, walletExits),
      "Buy wallet exit finalized"
    );
    require(
      !Exiting.isWalletExitFinalized(arguments.externalArguments.sell.wallet, walletExits),
      "Sell wallet exit finalized"
    );

    // Funding payments must be made prior to updating any position to ensure that the funding is calculated
    // against the position size at the time of each historic multipler
    Funding.updateWalletFunding(
      arguments.externalArguments.buy.wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.updateWalletFunding(
      arguments.externalArguments.sell.wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    _executeOrderBookTradeAfterFunding(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      completedOrderHashes,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol,
      nonceInvalidationsByWallet,
      partiallyFilledOrderQuantities
    );
  }

  function _executeOrderBookTradeAfterFunding(
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(bytes32 => bool) storage completedOrderHashes,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => NonceInvalidation[]) storage nonceInvalidationsByWallet,
    mapping(bytes32 => uint64) storage partiallyFilledOrderQuantities
  ) private {
    Market memory market = _validateTradeAndUpdateOrderBalancesAndFilledQuantities(
      arguments,
      completedOrderHashes,
      marketsByBaseAssetSymbol,
      nonceInvalidationsByWallet,
      partiallyFilledOrderQuantities
    );

    balanceTracking.updateForOrderBookTrade(
      arguments.externalArguments,
      arguments.feeWallet,
      market,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    _validateInitialMarginRequirements(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateTradeAndUpdateOrderBalancesAndFilledQuantities(
    Arguments memory arguments,
    mapping(bytes32 => bool) storage completedOrderHashes,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => NonceInvalidation[]) storage nonceInvalidationsByWallet,
    mapping(bytes32 => uint64) storage partiallyFilledOrderQuantities
  ) private returns (Market memory) {
    (bytes32 buyHash, bytes32 sellHash, Market memory market) = OrderBookTradeValidations.validateOrderBookTrade(
      arguments.externalArguments,
      arguments.delegateKeyExpirationPeriodInMs,
      arguments.exitFundWallet,
      arguments.insuranceFundWallet,
      marketsByBaseAssetSymbol,
      nonceInvalidationsByWallet
    );

    _updateOrderFilledQuantities(arguments, buyHash, sellHash, completedOrderHashes, partiallyFilledOrderQuantities);

    return market;
  }

  function _updateOrderFilledQuantities(
    Arguments memory arguments,
    bytes32 buyHash,
    bytes32 sellHash,
    mapping(bytes32 => bool) storage completedOrderHashes,
    mapping(bytes32 => uint64) storage partiallyFilledOrderQuantities
  ) private {
    // Buy side
    _updateOrderFilledQuantity(
      arguments.externalArguments.buy,
      buyHash,
      arguments.externalArguments.orderBookTrade.baseQuantity,
      completedOrderHashes,
      partiallyFilledOrderQuantities
    );
    // Sell side
    _updateOrderFilledQuantity(
      arguments.externalArguments.sell,
      sellHash,
      arguments.externalArguments.orderBookTrade.baseQuantity,
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

  function _validateInitialMarginRequirements(
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view {
    Margin.loadAndValidateTotalAccountValueAndInitialMarginRequirement(
      arguments.externalArguments.buy.wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
    Margin.loadAndValidateTotalAccountValueAndInitialMarginRequirement(
      arguments.externalArguments.sell.wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }
}
