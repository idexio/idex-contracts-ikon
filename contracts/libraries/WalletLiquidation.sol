// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { BalanceTracking } from "./BalanceTracking.sol";
import { ExitFund } from "./ExitFund.sol";
import { Funding } from "./Funding.sol";
import { LiquidationType } from "./Enums.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { Margin } from "./Margin.sol";
import { MarketOverrides } from "./MarketOverrides.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { Balance, FundingMultiplierQuartet, IndexPrice, Market } from "./Structs.sol";

library WalletLiquidation {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketOverrides for Market;
  using SortedStringSet for string[];

  /**
   * @dev Argument for `liquidateWallet`
   */
  struct Arguments {
    // External arguments
    LiquidationType liquidationType;
    address counterpartyWallet; // Insurance Fund or Exit Fund
    IndexPrice[] counterpartyWalletIndexPrices; // After acquiring liquidated positions
    address liquidatingWallet;
    IndexPrice[] liquidatingWalletIndexPrices;
    int64[] liquidationQuoteQuantitiesInPips;
    // Exchange state
    address[] indexPriceCollectionServiceWallets;
  }

  function liquidate(
    Arguments memory arguments,
    uint256 exitFundPositionOpenedAtBlockNumber,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public returns (uint256) {
    Funding.updateWalletFundingInternal(
      arguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.updateWalletFundingInternal(
      arguments.counterpartyWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    _liquidate(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    if (arguments.liquidationType == LiquidationType.WalletInMaintenanceDuringSystemRecovery) {
      return
        ExitFund.getExitFundBalanceOpenedAtBlockNumber(
          arguments.liquidatingWallet,
          exitFundPositionOpenedAtBlockNumber,
          balanceTracking,
          baseAssetSymbolsWithOpenPositionsByWallet
        );
    }

    return exitFundPositionOpenedAtBlockNumber;
  }

  function _liquidate(
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    // FIXME Do not allow liquidation of insurance or exit funds

    (int64 totalAccountValueInPips, uint64 totalMaintenanceMarginRequirementInPips) = Margin
      .loadTotalAccountValueAndMaintenanceMarginRequirement(
        Margin.LoadArguments(
          arguments.liquidatingWallet,
          arguments.liquidatingWalletIndexPrices,
          arguments.indexPriceCollectionServiceWallets
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    if (
      arguments.liquidationType == LiquidationType.WalletInMaintenance ||
      arguments.liquidationType == LiquidationType.WalletInMaintenanceDuringSystemRecovery
    ) {
      require(
        totalAccountValueInPips < int64(totalMaintenanceMarginRequirementInPips),
        "Maintenance margin requirement met"
      );
    }

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      _validateQuoteQuantityAndLiquidatePosition(
        i,
        arguments,
        marketsByBaseAssetSymbol[baseAssetSymbols[i]],
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet
      );
    }

    balanceTracking.updateQuoteForLiquidation(arguments.counterpartyWallet, arguments.liquidatingWallet);

    if (
      arguments.liquidationType == LiquidationType.WalletExited ||
      arguments.liquidationType == LiquidationType.WalletInMaintenance
    ) {
      // Validate that the Insurance Fund still meets its initial margin requirements
      Margin.loadAndValidateTotalAccountValueAndInitialMarginRequirement(
        Margin.LoadArguments(
          arguments.counterpartyWallet,
          arguments.counterpartyWalletIndexPrices,
          arguments.indexPriceCollectionServiceWallets
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    }
  }

  function _validateQuoteQuantityAndLiquidatePosition(
    uint8 index,
    Arguments memory arguments,
    Market memory market,
    int64 totalAccountValueInPips,
    uint64 totalMaintenanceMarginRequirementInPips,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    Balance storage balance = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.liquidatingWallet,
      market.baseAssetSymbol
    );
    Validations.validateIndexPrice(
      arguments.liquidatingWalletIndexPrices[index],
      market,
      arguments.indexPriceCollectionServiceWallets
    );

    if (
      arguments.liquidationType == LiquidationType.WalletInMaintenance ||
      arguments.liquidationType == LiquidationType.WalletInMaintenanceDuringSystemRecovery
    ) {
      LiquidationValidations.validateLiquidationQuoteQuantityToClosePositions(
        arguments.liquidationQuoteQuantitiesInPips[index],
        market
          .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .maintenanceMarginFractionInPips,
        arguments.liquidatingWalletIndexPrices[index].price,
        balance.balanceInPips,
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips
      );
    } else {
      // LiquidationType.WalletExited
      LiquidationValidations.validateExitQuoteQuantity(
        balance.costBasisInPips,
        arguments.liquidationQuoteQuantitiesInPips[index],
        arguments.liquidatingWalletIndexPrices[index].price,
        balance.balanceInPips,
        totalAccountValueInPips
      );
    }

    balanceTracking.updatePositionForLiquidation(
      balance.balanceInPips,
      arguments.counterpartyWallet,
      arguments.liquidatingWallet,
      market,
      arguments.liquidationQuoteQuantitiesInPips[index],
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }
}
