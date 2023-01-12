// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Funding } from "./Funding.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { MutatingMargin } from "./MutatingMargin.sol";
import { NonMutatingMargin } from "./NonMutatingMargin.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { FundingMultiplierQuartet, IndexPrice, Market, MarketOverrides, PositionInDeactivatedMarketLiquidationArguments } from "./Structs.sol";

library PositionInDeactivatedMarketLiquidation {
  using BalanceTracking for BalanceTracking.Storage;
  using SortedStringSet for string[];

  /**
   * @dev Argument for `liquidatePositionInDeactivatedMarket`
   */
  struct Arguments {
    PositionInDeactivatedMarketLiquidationArguments externalArguments;
    // Exchange state
    address feeWallet;
    address[] indexPriceCollectionServiceWallets;
  }

  // solhint-disable-next-line func-name-mixedcase
  function liquidate_delegatecall(
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    Funding.updateWalletFunding(
      arguments.externalArguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) = MutatingMargin
      .loadTotalAccountValueAndMaintenanceMarginRequirementAndUpdateLastIndexPrice(
        NonMutatingMargin.LoadArguments(
          arguments.externalArguments.liquidatingWallet,
          arguments.externalArguments.liquidatingWalletIndexPrices,
          arguments.indexPriceCollectionServiceWallets
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    require(totalAccountValue >= int64(totalMaintenanceMarginRequirement), "Maintenance margin requirement not met");

    _validateQuantitiesAndLiquidatePositionInDeactivatedMarket(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateQuantitiesAndLiquidatePositionInDeactivatedMarket(
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    Market memory market = marketsByBaseAssetSymbol[arguments.externalArguments.baseAssetSymbol];
    require(market.exists && !market.isActive, "No inactive market found");

    require(
      baseAssetSymbolsWithOpenPositionsByWallet[arguments.externalArguments.liquidatingWallet].indexOf(
        arguments.externalArguments.baseAssetSymbol
      ) != SortedStringSet.NOT_FOUND,
      "No open position in market"
    );

    // Validate quote quantity
    LiquidationValidations.validateDeactivatedMarketLiquidationQuoteQuantity(
      market.indexPriceAtDeactivation,
      balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
        arguments.externalArguments.liquidatingWallet,
        market.baseAssetSymbol
      ),
      arguments.externalArguments.liquidationQuoteQuantity
    );

    require(
      Validations.isFeeQuantityValid(
        arguments.externalArguments.feeQuantity,
        arguments.externalArguments.liquidationQuoteQuantity
      ),
      "Excessive maker fee"
    );

    balanceTracking.updatePositionForDeactivatedMarketLiquidation(
      market.baseAssetSymbol,
      arguments.externalArguments.feeQuantity,
      arguments.feeWallet,
      arguments.externalArguments.liquidatingWallet,
      arguments.externalArguments.liquidationQuoteQuantity,
      baseAssetSymbolsWithOpenPositionsByWallet
    );
  }
}
