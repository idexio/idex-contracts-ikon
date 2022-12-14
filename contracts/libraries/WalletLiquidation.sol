// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { BalanceTracking } from "./BalanceTracking.sol";
import { ExitFund } from "./ExitFund.sol";
import { Funding } from "./Funding.sol";
import { LiquidationType } from "./Enums.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { MutatingMargin } from "./MutatingMargin.sol";
import { NonMutatingMargin } from "./NonMutatingMargin.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { Balance, FundingMultiplierQuartet, IndexPrice, Market, MarketOverrides } from "./Structs.sol";

library WalletLiquidation {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
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
    int64[] liquidationQuoteQuantities;
    // Exchange state
    address exitFundWallet;
    address insuranceFundWallet;
    address[] indexPriceCollectionServiceWallets;
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
    require(arguments.liquidatingWallet != arguments.exitFundWallet, "Cannot liquidate EF");
    require(arguments.liquidatingWallet != arguments.insuranceFundWallet, "Cannot liquidate IF");

    Funding.updateWalletFunding(
      arguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.updateWalletFunding(
      arguments.counterpartyWallet,
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
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    if (arguments.liquidationType == LiquidationType.WalletInMaintenanceDuringSystemRecovery) {
      resultingExitFundPositionOpenedAtBlockNumber = ExitFund.getExitFundBalanceOpenedAtBlockNumber(
        arguments.liquidatingWallet,
        currentExitFundPositionOpenedAtBlockNumber,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet
      );
    } else {
      resultingExitFundPositionOpenedAtBlockNumber = currentExitFundPositionOpenedAtBlockNumber;

      // Validate that the Insurance Fund still meets its initial margin requirements
      MutatingMargin.loadAndValidateTotalAccountValueAndInitialMarginRequirementAndUpdateLastIndexPrice(
        NonMutatingMargin.LoadArguments(
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

  function _validateQuoteQuantitiesAndLiquidatePositions(
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    // FIXME Do not allow liquidation of insurance or exit funds

    (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) = MutatingMargin
      .loadTotalAccountValueAndMaintenanceMarginRequirementAndUpdateLastIndexPrice(
        NonMutatingMargin.LoadArguments(
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
      require(totalAccountValue < int64(totalMaintenanceMarginRequirement), "Maintenance margin requirement met");
    }

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      _validateQuoteQuantityAndLiquidatePosition(
        i,
        arguments,
        marketsByBaseAssetSymbol[baseAssetSymbols[i]],
        totalAccountValue,
        totalMaintenanceMarginRequirement,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet
      );
    }

    balanceTracking.updateQuoteForLiquidation(arguments.counterpartyWallet, arguments.liquidatingWallet);
  }

  function _validateQuoteQuantityAndLiquidatePosition(
    uint8 index,
    Arguments memory arguments,
    Market memory market,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    Balance storage balance = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.liquidatingWallet,
      market.baseAssetSymbol
    );
    Validations.validateIndexPrice(
      arguments.liquidatingWalletIndexPrices[index],
      arguments.indexPriceCollectionServiceWallets,
      market
    );

    if (
      arguments.liquidationType == LiquidationType.WalletInMaintenance ||
      arguments.liquidationType == LiquidationType.WalletInMaintenanceDuringSystemRecovery
    ) {
      LiquidationValidations.validateLiquidationQuoteQuantityToClosePositions(
        arguments.liquidationQuoteQuantities[index],
        market
          .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maintenanceMarginFraction,
        arguments.liquidatingWalletIndexPrices[index].price,
        balance.balance,
        totalAccountValue,
        totalMaintenanceMarginRequirement
      );
    } else {
      // LiquidationType.WalletExited
      LiquidationValidations.validateExitQuoteQuantity(
        balance.costBasis,
        arguments.liquidationQuoteQuantities[index],
        arguments.liquidatingWalletIndexPrices[index].price,
        balance.balance,
        totalAccountValue
      );
    }

    balanceTracking.updatePositionForLiquidation(
      balance.balance,
      arguments.counterpartyWallet,
      arguments.liquidatingWallet,
      market,
      arguments.liquidationQuoteQuantities[index],
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }
}