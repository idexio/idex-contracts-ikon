// SPDX-License-Identifier: MIT

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

library WalletExitLiquidation {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
  using SortedStringSet for string[];

  struct ValidateExitQuoteQuantityArguments {
    Market market;
    int64 exitAccountValue;
    uint64 quoteQuantity;
    int256 totalAccountValueInDoublePips;
    uint256 totalMaintenanceMarginRequirementInTriplePips;
    address wallet;
  }

  // Placing arguments in calldata avoids a stack too deep error from the Yul optimizer
  // solhint-disable-next-line func-name-mixedcase
  function liquidate_delegatecall(
    WalletLiquidationArguments calldata arguments,
    address exitFundWallet,
    address insuranceFundWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    // The EF and IF cannot be exited, so no need validate that they are not set as liquidating wallet
    require(arguments.counterpartyWallet == insuranceFundWallet, "Must liquidate to IF");

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

    // Validate that the Insurance Fund still meets its initial margin requirements
    IndexPriceMargin.validateInitialMarginRequirement(
      arguments.counterpartyWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
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
    ValidateExitQuoteQuantityArguments memory validateExitQuoteQuantityArguments;
    (
      validateExitQuoteQuantityArguments.exitAccountValue,
      validateExitQuoteQuantityArguments.totalAccountValueInDoublePips,
      validateExitQuoteQuantityArguments.totalMaintenanceMarginRequirementInTriplePips
    ) = IndexPriceMargin
      .loadTotalExitAccountValueAndAccountValueInDoublePipsAndMaintenanceMarginRequirementInTriplePips(
        arguments.liquidatingWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    validateExitQuoteQuantityArguments.wallet = arguments.liquidatingWallet;

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      validateExitQuoteQuantityArguments.market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      require(validateExitQuoteQuantityArguments.market.isActive, "Cannot liquidate position in inactive market");

      validateExitQuoteQuantityArguments.quoteQuantity = arguments.liquidationQuoteQuantities[i];

      _validateLiquidationQuoteQuantity(
        validateExitQuoteQuantityArguments,
        balanceTracking,
        marketOverridesByBaseAssetSymbolAndWallet
      );

      _updatePositionForLiquidation(
        arguments,
        exitFundWallet,
        i,
        validateExitQuoteQuantityArguments.market,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
      );
    }

    if (validateExitQuoteQuantityArguments.exitAccountValue <= 0) {
      // When liquidating at the bankruptcy price, a small amount of quote asset may be left over due to rounding
      // errors - sweep this remaining amount into the counterparty wallet to fully zero out the liquidating wallet
      balanceTracking.updateRemainingQuoteBalanceAfterWalletLiquidation(
        arguments.counterpartyWallet,
        arguments.liquidatingWallet
      );
    }
  }

  function _validateLiquidationQuoteQuantity(
    ValidateExitQuoteQuantityArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    Balance memory balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.wallet,
      arguments.market.baseAssetSymbol
    );

    if (arguments.exitAccountValue <= 0) {
      LiquidationValidations.validateQuoteQuantityAtBankruptcyPrice(
        arguments.market.lastIndexPrice,
        balanceStruct.balance,
        arguments.quoteQuantity,
        arguments
          .market
          .loadMarketWithOverridesForWallet(arguments.wallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maintenanceMarginFraction,
        arguments.totalAccountValueInDoublePips,
        arguments.totalMaintenanceMarginRequirementInTriplePips
      );
    } else {
      LiquidationValidations.validateQuoteQuantityAtExitPrice(
        balanceStruct.costBasis,
        arguments.market.lastIndexPrice,
        balanceStruct.balance,
        arguments.quoteQuantity
      );
    }
  }
}
