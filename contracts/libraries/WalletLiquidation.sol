// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { BalanceTracking } from "./BalanceTracking.sol";
import { ExitFund } from "./ExitFund.sol";
import { Funding } from "./Funding.sol";
import { IndexPriceMargin } from "./IndexPriceMargin.sol";
import { LiquidationType } from "./Enums.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Balance, FundingMultiplierQuartet, Market, MarketOverrides, WalletLiquidationArguments } from "./Structs.sol";

library WalletLiquidation {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
  using SortedStringSet for string[];

  // Placing arguments in calldata avoids a stack too deep error from the Yul optimizer
  // solhint-disable-next-line func-name-mixedcase
  function liquidate_delegatecall(
    WalletLiquidationArguments calldata arguments,
    uint256 currentExitFundPositionOpenedAtBlockNumber,
    address exitFundWallet,
    address insuranceFundWallet,
    LiquidationType liquidationType,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public returns (uint256 resultingExitFundPositionOpenedAtBlockNumber) {
    require(arguments.liquidatingWallet != exitFundWallet, "Cannot liquidate EF");
    require(arguments.liquidatingWallet != insuranceFundWallet, "Cannot liquidate IF");
    if (liquidationType == LiquidationType.WalletInMaintenanceDuringSystemRecovery) {
      require(arguments.counterpartyWallet == exitFundWallet, "Must liquidate to EF");
    } else {
      // LiquidationType.WalletInMaintenance, LiquidationType.WalletExited
      require(arguments.counterpartyWallet == insuranceFundWallet, "Must liquidate to IF");
    }

    Funding.applyOutstandingWalletFunding(
      arguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.applyOutstandingWalletFunding(
      arguments.counterpartyWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    _validateQuoteQuantitiesAndLiquidatePositions(
      arguments,
      exitFundWallet,
      liquidationType,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    if (liquidationType == LiquidationType.WalletInMaintenanceDuringSystemRecovery) {
      resultingExitFundPositionOpenedAtBlockNumber = ExitFund.getExitFundPositionOpenedAtBlockNumber(
        currentExitFundPositionOpenedAtBlockNumber,
        exitFundWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet
      );
    } else {
      resultingExitFundPositionOpenedAtBlockNumber = currentExitFundPositionOpenedAtBlockNumber;

      // Validate that the Insurance Fund still meets its initial margin requirements
      IndexPriceMargin.validateInitialMarginRequirement(
        arguments.counterpartyWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    }
  }

  // Wrap balance update to avoid stack too deep error
  function _updatePositionForLiquidation(
    WalletLiquidationArguments memory arguments,
    address exitFundWallet,
    uint8 index,
    Market memory market,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    Balance memory balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.liquidatingWallet,
      market.baseAssetSymbol
    );

    balanceTracking.updatePositionsForLiquidation(
      arguments.counterpartyWallet,
      exitFundWallet,
      arguments.liquidatingWallet,
      market,
      balanceStruct.balance,
      arguments.liquidationQuoteQuantities[index],
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function _validateQuoteQuantitiesAndLiquidatePositions(
    WalletLiquidationArguments memory arguments,
    address exitFundWallet,
    LiquidationType liquidationType,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    uint64 totalMaintenanceMarginRequirement = IndexPriceMargin.loadTotalMaintenanceMarginRequirement(
      arguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    int64 totalAccountValue;
    if (
      liquidationType == LiquidationType.WalletInMaintenance ||
      liquidationType == LiquidationType.WalletInMaintenanceDuringSystemRecovery
    ) {
      totalAccountValue = IndexPriceMargin.loadTotalAccountValue(
        arguments.liquidatingWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      );
      require(totalAccountValue < int64(totalMaintenanceMarginRequirement), "Maintenance margin requirement met");
    } else {
      totalAccountValue = IndexPriceMargin.loadExitAccountValue(
        arguments.liquidatingWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      );
    }

    Market memory market;
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      require(market.isActive, "Cannot liquidate position in inactive market");

      if (
        liquidationType == LiquidationType.WalletInMaintenance ||
        liquidationType == LiquidationType.WalletInMaintenanceDuringSystemRecovery
      ) {
        _validateWalletInMaintenanceLiquidationQuoteQuantity(
          arguments,
          i,
          market,
          totalAccountValue,
          totalMaintenanceMarginRequirement,
          balanceTracking,
          marketOverridesByBaseAssetSymbolAndWallet
        );
      } else {
        _validateWalletExitedLiquidationQuoteQuantity(
          arguments,
          totalAccountValue,
          i,
          market,
          totalMaintenanceMarginRequirement,
          balanceTracking,
          marketOverridesByBaseAssetSymbolAndWallet
        );
      }

      _updatePositionForLiquidation(
        arguments,
        exitFundWallet,
        i,
        marketsByBaseAssetSymbol[baseAssetSymbols[i]],
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
      );
    }

    // After closing all the positions for a wallet in maintenance, a small amount of quote asset may be left over
    // due to rounding errors - sweep this remaining amount into the counterparty wallet to fully zero out the
    // liquidating wallet. Note that we do not do this when liquidating an exited wallet because any quote remaining
    // after closing positions becomes available for withdrawal
    if (liquidationType != LiquidationType.WalletExited) {
      balanceTracking.updateRemainingQuoteBalanceAfterWalletLiquidation(
        arguments.counterpartyWallet,
        arguments.liquidatingWallet
      );
    }
  }

  function _validateWalletInMaintenanceLiquidationQuoteQuantity(
    WalletLiquidationArguments memory arguments,
    uint8 index,
    Market memory market,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    LiquidationValidations.validateLiquidationQuoteQuantityToClosePositions(
      market.lastIndexPrice,
      arguments.liquidationQuoteQuantities[index],
      market
        .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
        .overridableFields
        .maintenanceMarginFraction,
      balanceTracking.loadBalanceAndMigrateIfNeeded(arguments.liquidatingWallet, market.baseAssetSymbol),
      totalAccountValue,
      totalMaintenanceMarginRequirement
    );
  }

  function _validateWalletExitedLiquidationQuoteQuantity(
    WalletLiquidationArguments memory arguments,
    int64 exitAccountValue,
    uint8 index,
    Market memory market,
    uint64 totalMaintenanceMarginRequirement,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    Balance memory balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.liquidatingWallet,
      market.baseAssetSymbol
    );

    if (exitAccountValue < 0) {
      LiquidationValidations.validateLiquidationQuoteQuantityToClosePositions(
        market.lastIndexPrice,
        arguments.liquidationQuoteQuantities[index],
        market
          .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maintenanceMarginFraction,
        balanceStruct.balance,
        exitAccountValue,
        totalMaintenanceMarginRequirement
      );
    } else {
      LiquidationValidations.validateExitQuoteQuantityByExitPrice(
        balanceStruct.costBasis,
        arguments.liquidationQuoteQuantities[index],
        market.lastIndexPrice,
        balanceStruct.balance
      );
    }
  }
}
