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

  /**
   * @dev Argument for `liquidateWallet`
   */
  struct Arguments {
    WalletLiquidationArguments externalArguments;
    LiquidationType liquidationType;
    // Exchange state
    address exitFundWallet;
    address insuranceFundWallet;
  }

  // solhint-disable-next-line func-name-mixedcase
  function liquidate_delegatecall(
    Arguments memory arguments,
    uint256 currentExitFundPositionOpenedAtBlockNumber,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public returns (uint256 resultingExitFundPositionOpenedAtBlockNumber) {
    require(arguments.externalArguments.liquidatingWallet != arguments.exitFundWallet, "Cannot liquidate EF");
    require(arguments.externalArguments.liquidatingWallet != arguments.insuranceFundWallet, "Cannot liquidate IF");
    if (arguments.liquidationType == LiquidationType.WalletInMaintenanceDuringSystemRecovery) {
      require(arguments.externalArguments.counterpartyWallet == arguments.exitFundWallet, "Must liquidate to EF");
    } else {
      // LiquidationType.WalletInMaintenance, LiquidationType.WalletExited
      require(arguments.externalArguments.counterpartyWallet == arguments.insuranceFundWallet, "Must liquidate to IF");
    }

    Funding.updateWalletFunding(
      arguments.externalArguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.updateWalletFunding(
      arguments.externalArguments.counterpartyWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    _validateQuoteQuantitiesAndLiquidatePositions(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    if (arguments.liquidationType == LiquidationType.WalletInMaintenanceDuringSystemRecovery) {
      resultingExitFundPositionOpenedAtBlockNumber = ExitFund.getExitFundBalanceOpenedAtBlockNumber(
        arguments.exitFundWallet,
        currentExitFundPositionOpenedAtBlockNumber,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet
      );
    } else {
      resultingExitFundPositionOpenedAtBlockNumber = currentExitFundPositionOpenedAtBlockNumber;

      // Validate that the Insurance Fund still meets its initial margin requirements
      IndexPriceMargin.loadAndValidateTotalAccountValueAndInitialMarginRequirement(
        arguments.externalArguments.counterpartyWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    }
  }

  function _validateQuoteQuantitiesAndLiquidatePositions(
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) = IndexPriceMargin
      .loadTotalAccountValueAndMaintenanceMarginRequirement(
        arguments.externalArguments.liquidatingWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    if (
      arguments.liquidationType == LiquidationType.WalletInMaintenance ||
      arguments.liquidationType == LiquidationType.WalletInMaintenanceDuringSystemRecovery
    ) {
      require(totalAccountValue < int64(totalMaintenanceMarginRequirement), "Maintenance margin requirement met");
    }

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
      arguments.externalArguments.liquidatingWallet
    ];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      _validateQuoteQuantityAndLiquidatePosition(
        i,
        arguments,
        marketsByBaseAssetSymbol[baseAssetSymbols[i]],
        totalAccountValue,
        totalMaintenanceMarginRequirement,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
      );
    }

    balanceTracking.updateQuoteForLiquidation(
      arguments.externalArguments.counterpartyWallet,
      arguments.externalArguments.liquidatingWallet
    );
  }

  function _validateQuoteQuantityAndLiquidatePosition(
    uint8 index,
    Arguments memory arguments,
    Market memory market,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    require(market.isActive, "Cannot liquidate position in inactive market");

    Balance memory balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.externalArguments.liquidatingWallet,
      market.baseAssetSymbol
    );

    // Validate quote quantity
    if (
      arguments.liquidationType == LiquidationType.WalletInMaintenance ||
      arguments.liquidationType == LiquidationType.WalletInMaintenanceDuringSystemRecovery
    ) {
      LiquidationValidations.validateLiquidationQuoteQuantityToClosePositions(
        arguments.externalArguments.liquidationQuoteQuantities[index],
        market
          .loadMarketWithOverridesForWallet(
            arguments.externalArguments.liquidatingWallet,
            marketOverridesByBaseAssetSymbolAndWallet
          )
          .overridableFields
          .maintenanceMarginFraction,
        market.lastIndexPrice,
        balanceStruct.balance,
        totalAccountValue,
        totalMaintenanceMarginRequirement
      );
    } else {
      // LiquidationType.WalletExited
      LiquidationValidations.validateExitQuoteQuantity(
        balanceStruct.costBasis,
        arguments.externalArguments.liquidationQuoteQuantities[index],
        market.lastIndexPrice,
        market
          .loadMarketWithOverridesForWallet(
            arguments.externalArguments.liquidatingWallet,
            marketOverridesByBaseAssetSymbolAndWallet
          )
          .overridableFields
          .maintenanceMarginFraction,
        balanceStruct.balance,
        totalAccountValue,
        totalMaintenanceMarginRequirement
      );
    }

    balanceTracking.updatePositionForLiquidation(
      arguments.externalArguments.counterpartyWallet,
      arguments.externalArguments.liquidatingWallet,
      market,
      balanceStruct.balance,
      arguments.externalArguments.liquidationQuoteQuantities[index],
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }
}
