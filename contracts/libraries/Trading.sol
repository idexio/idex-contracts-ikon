// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { Funding } from "./Funding.sol";
import { IndexPriceMargin } from "./IndexPriceMargin.sol";
import { OrderSide } from "./Enums.sol";
import { TradeValidations } from "./TradeValidations.sol";
import { WalletExits } from "./WalletExits.sol";
import { ExecuteTradeArguments, FundingMultiplierQuartet, Market, MarketOverrides, Order, NonceInvalidation, WalletExit } from "./Structs.sol";

library Trading {
  using BalanceTracking for BalanceTracking.Storage;

  struct Arguments {
    ExecuteTradeArguments externalArguments;
    // Exchange state
    uint64 delegateKeyExpirationPeriodInMs;
    bytes32 domainSeparator;
    address exitFundWallet;
    address feeWallet;
    address insuranceFundWallet;
  }

  /**
   * @notice Emitted when the Dispatcher Wallet submits a trade for execution with `executeTrade` and one of the orders
   * has `isLiquidationAcquisitionOnly` asserted
   */
  event LiquidationAcquisitionExecuted(
    address buyWallet,
    address sellWallet,
    string baseAssetSymbol,
    string quoteAssetSymbol,
    uint64 baseQuantity,
    uint64 quoteQuantity,
    OrderSide makerSide,
    int64 makerFeeQuantity,
    uint64 takerFeeQuantity
  );

  /**
   * @notice Emitted when the Dispatcher Wallet submits a trade for execution with `executeTrade`
   */
  event TradeExecuted(
    address buyWallet,
    address sellWallet,
    string baseAssetSymbol,
    string quoteAssetSymbol,
    uint64 baseQuantity,
    uint64 quoteQuantity,
    OrderSide makerSide,
    int64 makerFeeQuantity,
    uint64 takerFeeQuantity
  );

  // Placing arguments in calldata avoids a stack too deep error from the Yul optimizer
  // solhint-disable-next-line func-name-mixedcase
  function executeTrade_delegatecall(
    Arguments calldata arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(bytes32 => bool) storage completedOrderHashes,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => NonceInvalidation[]) storage nonceInvalidationsByWallet,
    mapping(bytes32 => uint64) storage partiallyFilledOrderQuantities,
    mapping(address => WalletExit) storage walletExits
  ) public {
    require(
      !WalletExits.isWalletExitFinalized(arguments.externalArguments.buy.wallet, walletExits),
      "Buy wallet exit finalized"
    );
    require(
      !WalletExits.isWalletExitFinalized(arguments.externalArguments.sell.wallet, walletExits),
      "Sell wallet exit finalized"
    );

    // Funding payments must be made prior to updating any position to ensure that the funding is calculated
    // against the position size at the time of each historic multiplier
    Funding.applyOutstandingWalletFunding(
      arguments.externalArguments.buy.wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.applyOutstandingWalletFunding(
      arguments.externalArguments.sell.wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    _executeTradeAfterFunding(
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

    _emitTradeExecutedEvent(arguments.externalArguments);
  }

  function _emitTradeExecutedEvent(ExecuteTradeArguments memory tradeArguments) private {
    // Either both or none of the orders will have `isLiquidationAcquisitionOnly` asserted as validated by
    // `TradeValidations.validateTrade`
    if (tradeArguments.buy.isLiquidationAcquisitionOnly) {
      emit LiquidationAcquisitionExecuted(
        tradeArguments.buy.wallet,
        tradeArguments.sell.wallet,
        tradeArguments.trade.baseAssetSymbol,
        Constants.QUOTE_ASSET_SYMBOL,
        tradeArguments.trade.baseQuantity,
        tradeArguments.trade.quoteQuantity,
        tradeArguments.trade.makerSide,
        tradeArguments.trade.makerFeeQuantity,
        tradeArguments.trade.takerFeeQuantity
      );
    } else {
      emit TradeExecuted(
        tradeArguments.buy.wallet,
        tradeArguments.sell.wallet,
        tradeArguments.trade.baseAssetSymbol,
        Constants.QUOTE_ASSET_SYMBOL,
        tradeArguments.trade.baseQuantity,
        tradeArguments.trade.quoteQuantity,
        tradeArguments.trade.makerSide,
        tradeArguments.trade.makerFeeQuantity,
        tradeArguments.trade.takerFeeQuantity
      );
    }
  }

  function _executeTradeAfterFunding(
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

    _updateBalancesAndValidateMarginRequirements(
      arguments,
      market,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _updateBalancesAndValidateMarginRequirements(
    Arguments memory arguments,
    Market memory market,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    (bool wasBuyPositionReduced, bool wasSellPositionReduced) = balanceTracking.updateForTrade(
      arguments.externalArguments,
      arguments.feeWallet,
      market,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    _validateMarginRequirements(
      arguments,
      wasBuyPositionReduced,
      wasSellPositionReduced,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
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
      arguments.externalArguments.trade.baseQuantity,
      completedOrderHashes,
      partiallyFilledOrderQuantities
    );
    // Sell side
    _updateOrderFilledQuantity(
      arguments.externalArguments.sell,
      sellHash,
      arguments.externalArguments.trade.baseQuantity,
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

    // Track partially filled quantities in base terms
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

  function _validateMarginRequirements(
    Arguments memory arguments,
    bool wasBuyPositionReduced,
    bool wasSellPositionReduced,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view {
    if (wasBuyPositionReduced) {
      IndexPriceMargin.validateMaintenanceMarginRequirement(
        arguments.externalArguments.buy.wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    } else {
      IndexPriceMargin.validateInitialMarginRequirement(
        arguments.externalArguments.buy.wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    }

    if (wasSellPositionReduced) {
      IndexPriceMargin.validateMaintenanceMarginRequirement(
        arguments.externalArguments.sell.wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    } else {
      IndexPriceMargin.validateInitialMarginRequirement(
        arguments.externalArguments.sell.wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    }
  }

  function _validateTradeAndUpdateOrderBalancesAndFilledQuantities(
    Arguments memory arguments,
    mapping(bytes32 => bool) storage completedOrderHashes,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => NonceInvalidation[]) storage nonceInvalidationsByWallet,
    mapping(bytes32 => uint64) storage partiallyFilledOrderQuantities
  ) private returns (Market memory) {
    (bytes32 buyHash, bytes32 sellHash, Market memory market) = TradeValidations.validateTrade(
      arguments.externalArguments,
      arguments.delegateKeyExpirationPeriodInMs,
      arguments.domainSeparator,
      arguments.exitFundWallet,
      arguments.insuranceFundWallet,
      marketsByBaseAssetSymbol,
      nonceInvalidationsByWallet
    );

    _updateOrderFilledQuantities(arguments, buyHash, sellHash, completedOrderHashes, partiallyFilledOrderQuantities);

    return market;
  }
}
