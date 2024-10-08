// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Funding } from "./Funding.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { Math } from "./Math.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { FundingMultiplierQuartet, Market, PositionInDeactivatedMarketLiquidationArguments } from "./Structs.sol";

library PositionInDeactivatedMarketLiquidation {
  using BalanceTracking for BalanceTracking.Storage;
  using SortedStringSet for string[];

  /**
   * @notice Emitted when the Dispatcher Wallet submits a position in deactivated market liquidation with
   * `liquidatePositionInDeactivatedMarket`
   */
  event LiquidatedPositionInDeactivatedMarket(
    string baseAssetSymbol,
    address liquidatingWallet,
    uint64 liquidationBaseQuantity,
    uint64 liquidationQuoteQuantity
  );

  // solhint-disable-next-line func-name-mixedcase
  function liquidate_delegatecall(
    PositionInDeactivatedMarketLiquidationArguments memory arguments,
    address feeWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    Funding.applyOutstandingWalletFunding(
      arguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    Market memory market = Validations.loadAndValidateInactiveMarket(
      arguments.baseAssetSymbol,
      arguments.liquidatingWallet,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    // Validate quote quantity
    int64 positionSize = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
      arguments.liquidatingWallet,
      market.baseAssetSymbol
    );
    LiquidationValidations.validateDeactivatedMarketLiquidationQuoteQuantity(
      market.indexPriceAtDeactivation,
      positionSize,
      arguments.liquidationQuoteQuantity
    );

    require(Validations.isFeeQuantityValid(arguments.feeQuantity, arguments.liquidationQuoteQuantity), "Excessive fee");

    balanceTracking.updatePositionForDeactivatedMarketLiquidation(
      market.baseAssetSymbol,
      arguments.feeQuantity,
      feeWallet,
      arguments.liquidatingWallet,
      arguments.liquidationQuoteQuantity,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    emit LiquidatedPositionInDeactivatedMarket(
      arguments.baseAssetSymbol,
      arguments.liquidatingWallet,
      Math.abs(positionSize),
      arguments.liquidationQuoteQuantity
    );
  }
}
