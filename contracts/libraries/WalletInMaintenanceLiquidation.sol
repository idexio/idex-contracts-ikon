// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { ExitFund } from "./ExitFund.sol";
import { Funding } from "./Funding.sol";
import { IndexPriceMargin } from "./IndexPriceMargin.sol";
import { LiquidationType } from "./Enums.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Math } from "./Math.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Balance, FundingMultiplierQuartet, Market, MarketOverrides, WalletLiquidationArguments } from "./Structs.sol";

library WalletInMaintenanceLiquidation {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
  using SortedStringSet for string[];

  /**
   * @notice Emitted when the Dispatcher Wallet submits a wallet in maintenance liquidation with
   * `liquidateWalletInMaintenance`
   */
  event LiquidatedWalletInMaintenance(address liquidatingWallet);
  /**
   * @notice Emitted when the Dispatcher Wallet submits a wallet in maintenance liquidation during system recovery with
   * `liquidateWalletInMaintenanceDuringSystemRecovery`
   */
  event LiquidatedWalletInMaintenanceDuringSystemRecovery(address liquidatingWallet);

  // Placing arguments in calldata avoids a stack too deep error from the Yul optimizer
  // solhint-disable-next-line func-name-mixedcase
  function liquidate_delegatecall(
    WalletLiquidationArguments calldata arguments,
    uint256 currentExitFundPositionOpenedAtBlockTimestamp,
    address exitFundWallet,
    address insuranceFundWallet,
    LiquidationType liquidationType,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public returns (uint256 resultingExitFundPositionOpenedAtBlockTimestamp) {
    require(arguments.liquidatingWallet != exitFundWallet, "Cannot liquidate EF");
    require(arguments.liquidatingWallet != insuranceFundWallet, "Cannot liquidate IF");
    if (liquidationType == LiquidationType.WalletInMaintenanceDuringSystemRecovery) {
      require(arguments.counterpartyWallet == exitFundWallet, "Must liquidate to EF");
    } else {
      // LiquidationType.WalletInMaintenance
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
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    if (liquidationType == LiquidationType.WalletInMaintenanceDuringSystemRecovery) {
      resultingExitFundPositionOpenedAtBlockTimestamp = ExitFund.getExitFundPositionOpenedAtBlockTimestamp(
        currentExitFundPositionOpenedAtBlockTimestamp,
        exitFundWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet
      );

      emit LiquidatedWalletInMaintenanceDuringSystemRecovery(arguments.liquidatingWallet);
    } else {
      resultingExitFundPositionOpenedAtBlockTimestamp = currentExitFundPositionOpenedAtBlockTimestamp;

      // Validate that the Insurance Fund still meets its initial margin requirements
      IndexPriceMargin.validateInitialMarginRequirement(
        arguments.counterpartyWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );

      emit LiquidatedWalletInMaintenance(arguments.liquidatingWallet);
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
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    (int256 totalAccountValueInDoublePips, uint256 totalMaintenanceMarginRequirementInTriplePips) = IndexPriceMargin
      .loadTotalAccountValueInDoublePipsAndMaintenanceMarginRequirementInTriplePips(
        arguments.liquidatingWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    require(
      Math.doublePipsToPips(totalAccountValueInDoublePips) <
        Math.toInt64(Math.triplePipsToPips(totalMaintenanceMarginRequirementInTriplePips)),
      "Maintenance margin requirement met"
    );

    Market memory market;
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      require(market.isActive, "Cannot liquidate position in inactive market");

      _validateLiquidationQuoteQuantity(
        arguments,
        i,
        market,
        totalAccountValueInDoublePips,
        totalMaintenanceMarginRequirementInTriplePips,
        balanceTracking,
        marketOverridesByBaseAssetSymbolAndWallet
      );

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
    // liquidating wallet
    balanceTracking.updateRemainingQuoteBalanceAfterWalletLiquidation(
      arguments.counterpartyWallet,
      arguments.liquidatingWallet
    );
  }

  function _validateLiquidationQuoteQuantity(
    WalletLiquidationArguments memory arguments,
    uint8 index,
    Market memory market,
    int256 totalAccountValueInDoublePips,
    uint256 totalMaintenanceMarginRequirementInTriplePips,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    LiquidationValidations.validateQuoteQuantityAtBankruptcyPrice(
      market.lastIndexPrice,
      balanceTracking.loadBalanceAndMigrateIfNeeded(arguments.liquidatingWallet, market.baseAssetSymbol),
      arguments.liquidationQuoteQuantities[index],
      market
        .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
        .overridableFields
        .maintenanceMarginFraction,
      totalAccountValueInDoublePips,
      totalMaintenanceMarginRequirementInTriplePips
    );
  }
}
