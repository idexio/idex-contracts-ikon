// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Funding } from "./Funding.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { Margin } from "./Margin.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { FundingMultiplierQuartet, IndexPrice, Market, MarketOverrides, PositionInDeactivatedMarketLiquidationArguments } from "./Structs.sol";

library PositionInDeactivatedMarketLiquidation {
  using BalanceTracking for BalanceTracking.Storage;
  using SortedStringSet for string[];

  // solhint-disable-next-line func-name-mixedcase
  function liquidate_delegatecall(
    PositionInDeactivatedMarketLiquidationArguments memory externalArguments,
    address feeWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    Funding.updateWalletFunding(
      externalArguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) = Margin
      .loadTotalAccountValueAndMaintenanceMarginRequirement(
        externalArguments.liquidatingWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    require(totalAccountValue >= int64(totalMaintenanceMarginRequirement), "Maintenance margin requirement not met");

    _validateQuantitiesAndLiquidatePositionInDeactivatedMarket(
      externalArguments,
      feeWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateQuantitiesAndLiquidatePositionInDeactivatedMarket(
    PositionInDeactivatedMarketLiquidationArguments memory externalArguments,
    address feeWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    Market memory market = marketsByBaseAssetSymbol[externalArguments.baseAssetSymbol];
    require(market.exists && !market.isActive, "No inactive market found");

    require(
      baseAssetSymbolsWithOpenPositionsByWallet[externalArguments.liquidatingWallet].indexOf(
        externalArguments.baseAssetSymbol
      ) != SortedStringSet.NOT_FOUND,
      "No open position in market"
    );

    // Validate quote quantity
    LiquidationValidations.validateDeactivatedMarketLiquidationQuoteQuantity(
      market.indexPriceAtDeactivation,
      balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
        externalArguments.liquidatingWallet,
        market.baseAssetSymbol
      ),
      externalArguments.liquidationQuoteQuantity
    );

    require(
      Validations.isFeeQuantityValid(externalArguments.feeQuantity, externalArguments.liquidationQuoteQuantity),
      "Excessive maker fee"
    );

    balanceTracking.updatePositionForDeactivatedMarketLiquidation(
      market.baseAssetSymbol,
      externalArguments.feeQuantity,
      feeWallet,
      externalArguments.liquidatingWallet,
      externalArguments.liquidationQuoteQuantity,
      baseAssetSymbolsWithOpenPositionsByWallet
    );
  }
}
