// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Funding } from "./Funding.sol";
import { IndexPriceMargin } from "./IndexPriceMargin.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Math } from "./Math.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { AcquisitionDeleverageArguments, Balance, FundingMultiplierQuartet, Market, MarketOverrides, WalletExit } from "./Structs.sol";
import { WalletExitAcquisitionDeleveragePriceStrategy } from "./Enums.sol";

library WalletExitAcquisitionDeleveraging {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
  using SortedStringSet for string[];

  struct ValidateExitQuoteQuantityArguments {
    WalletExitAcquisitionDeleveragePriceStrategy deleveragePriceStrategy;
    uint64 indexPrice;
    int64 liquidationBaseQuantity;
    uint64 liquidationQuoteQuantity;
    uint64 maintenanceMarginFraction;
    int64 totalAccountValue;
    uint64 totalMaintenanceMarginRequirement;
  }

  // solhint-disable-next-line func-name-mixedcase
  function deleverage_delegatecall(
    AcquisitionDeleverageArguments memory arguments,
    address exitFundWallet,
    address insuranceFundWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => WalletExit) storage walletExits
  ) public {
    require(arguments.liquidatingWallet != arguments.counterpartyWallet, "Cannot liquidate wallet against itself");
    // The EF and IF cannot be exited, so no need validate that they are not set as liquidating wallet
    require(arguments.counterpartyWallet != exitFundWallet, "Cannot deleverage EF");
    require(arguments.counterpartyWallet != insuranceFundWallet, "Cannot deleverage IF");

    Funding.applyOutstandingWalletFunding(
      arguments.counterpartyWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.applyOutstandingWalletFunding(
      arguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    _validateArgumentsAndDeleverage(
      arguments,
      exitFundWallet,
      insuranceFundWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol,
      walletExits
    );
  }

  function _determineAndStoreDeleveragePriceStrategy(
    int64 exitAccountValue,
    address wallet,
    mapping(address => WalletExit) storage walletExits
  ) private returns (WalletExitAcquisitionDeleveragePriceStrategy) {
    WalletExit storage walletExit = walletExits[wallet];

    // Once we select bankruptcy price use it for the remainder of exit deleveraging
    if (walletExit.deleveragePriceStrategy == WalletExitAcquisitionDeleveragePriceStrategy.BankruptcyPrice) {
      return WalletExitAcquisitionDeleveragePriceStrategy.BankruptcyPrice;
    }

    // Wallets with a positive total account value should use the exit price (worse of entry price or current index
    // price) unless a change in index pricing between deleveraging the wallet positions moves its exit account value
    // negative, at which point the bankruptcy price will be used for the remainder of the positions
    walletExit.deleveragePriceStrategy = exitAccountValue <= 0
      ? WalletExitAcquisitionDeleveragePriceStrategy.BankruptcyPrice
      : WalletExitAcquisitionDeleveragePriceStrategy.ExitPrice;

    return walletExit.deleveragePriceStrategy;
  }

  function _updatePositionsForDeleverage(
    AcquisitionDeleverageArguments memory arguments,
    address exitFundWallet,
    Market memory market,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    balanceTracking.updatePositionsForDeleverage(
      arguments.liquidationBaseQuantity,
      arguments.counterpartyWallet,
      exitFundWallet,
      arguments.liquidatingWallet,
      market,
      arguments.liquidationQuoteQuantity,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    // Validate that the counterparty wallet still meets its initial margin requirements
    IndexPriceMargin.validateInitialMarginRequirement(
      arguments.counterpartyWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateArgumentsAndDeleverage(
    AcquisitionDeleverageArguments memory arguments,
    address exitFundWallet,
    address insuranceFundWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => WalletExit) storage walletExits
  ) private {
    require(
      baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet].indexOf(arguments.baseAssetSymbol) !=
        SortedStringSet.NOT_FOUND,
      "No open position in market"
    );

    (
      int64 exitAccountValue,
      int64 liquidatingWalletTotalAccountValue,
      uint64 liquidatingWalletTotalMaintenanceMarginRequirement
    ) = IndexPriceMargin.loadExitAccountValueAndTotalAccountValueAndMaintenanceMarginRequirement(
        arguments.liquidatingWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );

    // Determine price strategy to use for subsequent IF acquisition simulation and actual position deleverage
    WalletExitAcquisitionDeleveragePriceStrategy deleveragePriceStrategy = _determineAndStoreDeleveragePriceStrategy(
      exitAccountValue,
      arguments.liquidatingWallet,
      walletExits
    );

    // Do not proceed with deleverage if the Insurance Fund can acquire the wallet's positions
    _validateInsuranceFundCannotLiquidateWallet(
      arguments,
      deleveragePriceStrategy,
      insuranceFundWallet,
      liquidatingWalletTotalAccountValue,
      liquidatingWalletTotalMaintenanceMarginRequirement,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    // Liquidate specified position by deleveraging a counterparty position
    _validateDeleverageQuoteQuantityAndUpdatePositions(
      arguments,
      deleveragePriceStrategy,
      exitFundWallet,
      liquidatingWalletTotalAccountValue,
      liquidatingWalletTotalMaintenanceMarginRequirement,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateDeleverageQuoteQuantity(
    AcquisitionDeleverageArguments memory arguments,
    WalletExitAcquisitionDeleveragePriceStrategy deleveragePriceStrategy,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private returns (Market memory market) {
    market = Validations.loadAndValidateActiveMarket(
      arguments.baseAssetSymbol,
      arguments.liquidatingWallet,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    Balance memory balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.liquidatingWallet,
      market.baseAssetSymbol
    );

    ValidateExitQuoteQuantityArguments memory validateExitQuoteQuantityArguments;
    validateExitQuoteQuantityArguments.deleveragePriceStrategy = deleveragePriceStrategy;
    validateExitQuoteQuantityArguments.indexPrice = market.lastIndexPrice;
    validateExitQuoteQuantityArguments.liquidationBaseQuantity = balanceStruct.balance < 0
      ? (-1 * int64(arguments.liquidationBaseQuantity))
      : int64(arguments.liquidationBaseQuantity);
    validateExitQuoteQuantityArguments.liquidationQuoteQuantity = arguments.liquidationQuoteQuantity;
    validateExitQuoteQuantityArguments.maintenanceMarginFraction = market
      .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
      .overridableFields
      .maintenanceMarginFraction;
    validateExitQuoteQuantityArguments.totalAccountValue = totalAccountValue;
    validateExitQuoteQuantityArguments.totalMaintenanceMarginRequirement = totalMaintenanceMarginRequirement;
    _validateExitQuoteQuantity(balanceStruct, validateExitQuoteQuantityArguments);
  }

  function _validateDeleverageQuoteQuantityAndUpdatePositions(
    AcquisitionDeleverageArguments memory arguments,
    WalletExitAcquisitionDeleveragePriceStrategy deleveragePriceStrategy,
    address exitFundWallet,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    Market memory market = _validateDeleverageQuoteQuantity(
      arguments,
      deleveragePriceStrategy,
      totalAccountValue,
      totalMaintenanceMarginRequirement,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    _updatePositionsForDeleverage(
      arguments,
      exitFundWallet,
      market,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateExitQuoteQuantity(
    Balance memory balanceStruct,
    ValidateExitQuoteQuantityArguments memory arguments
  ) private pure {
    if (arguments.deleveragePriceStrategy == WalletExitAcquisitionDeleveragePriceStrategy.ExitPrice) {
      LiquidationValidations.validateQuoteQuantityAtExitPrice(
        // Calculate the cost basis of the base quantity being liquidated while observing signedness
        Math.multiplyPipsByFraction(
          balanceStruct.costBasis,
          arguments.liquidationBaseQuantity,
          // Position size implicitly validated non-zero by `Validations.loadAndValidateActiveMarket`
          int64(Math.abs(balanceStruct.balance))
        ),
        arguments.indexPrice,
        arguments.liquidationBaseQuantity,
        arguments.liquidationQuoteQuantity
      );
    } else {
      LiquidationValidations.validateQuoteQuantityAtBankruptcyPrice(
        arguments.indexPrice,
        arguments.liquidationBaseQuantity,
        arguments.liquidationQuoteQuantity,
        arguments.maintenanceMarginFraction,
        arguments.totalAccountValue,
        arguments.totalMaintenanceMarginRequirement
      );
    }
  }

  function _validateInsuranceFundCannotLiquidateWallet(
    AcquisitionDeleverageArguments memory arguments,
    WalletExitAcquisitionDeleveragePriceStrategy deleveragePriceStrategy,
    address insuranceFundWallet,
    int64 liquidatingWalletTotalAccountValue,
    uint64 liquidatingWalletTotalMaintenanceMarginRequirement,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    // Build array of union of open position base asset symbols for both liquidating and IF wallets. Result of merge
    // will already be de-duped and sorted
    string[] memory baseAssetSymbolsForInsuranceFundAndLiquidatingWallet = baseAssetSymbolsWithOpenPositionsByWallet[
      insuranceFundWallet
    ].merge(baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet]);

    // Allocate struct to hold arguments needed to perform validation against IF liquidation of wallet
    IndexPriceMargin.ValidateInsuranceFundCannotLiquidateWalletArguments
      memory validateInsuranceFundCannotLiquidateWalletArguments = IndexPriceMargin
        .ValidateInsuranceFundCannotLiquidateWalletArguments(
          insuranceFundWallet,
          arguments.liquidatingWallet,
          arguments.validateInsuranceFundCannotLiquidateWalletQuoteQuantities,
          new Market[](baseAssetSymbolsForInsuranceFundAndLiquidatingWallet.length)
        );

    ValidateExitQuoteQuantityArguments memory validateExitQuoteQuantityArguments;
    validateExitQuoteQuantityArguments.deleveragePriceStrategy = deleveragePriceStrategy;
    validateExitQuoteQuantityArguments.totalAccountValue = liquidatingWalletTotalAccountValue;
    validateExitQuoteQuantityArguments
      .totalMaintenanceMarginRequirement = liquidatingWalletTotalMaintenanceMarginRequirement;

    Balance memory balanceStruct;
    Market memory market;
    // Loop through open position union and populate argument struct fields
    for (uint8 i = 0; i < baseAssetSymbolsForInsuranceFundAndLiquidatingWallet.length; i++) {
      // Load market
      market = marketsByBaseAssetSymbol[baseAssetSymbolsForInsuranceFundAndLiquidatingWallet[i]];
      validateInsuranceFundCannotLiquidateWalletArguments.markets[i] = market;

      balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
        arguments.liquidatingWallet,
        market.baseAssetSymbol
      );

      validateExitQuoteQuantityArguments.indexPrice = market.lastIndexPrice;
      validateExitQuoteQuantityArguments.liquidationBaseQuantity = balanceStruct.balance;
      validateExitQuoteQuantityArguments.liquidationQuoteQuantity = arguments
        .validateInsuranceFundCannotLiquidateWalletQuoteQuantities[i];
      validateExitQuoteQuantityArguments.maintenanceMarginFraction = market
        .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
        .overridableFields
        .maintenanceMarginFraction;

      _validateExitQuoteQuantity(balanceStruct, validateExitQuoteQuantityArguments);
    }

    // Argument struct is populated with validated field values, pass through to margin validation
    IndexPriceMargin.validateInsuranceFundCannotLiquidateWallet(
      validateInsuranceFundCannotLiquidateWalletArguments,
      balanceTracking,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }
}
