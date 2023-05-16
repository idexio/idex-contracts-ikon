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

  struct ValidateDeleverageQuoteQuantityArguments {
    AcquisitionDeleverageArguments acquisitionDeleverageArguments;
    WalletExitAcquisitionDeleveragePriceStrategy deleveragePriceStrategy;
    address exitFundWallet;
    int64 liquidatingWalletTotalAccountValue;
    uint64 liquidatingWalletTotalMaintenanceMarginRequirement;
  }

  struct ValidateExitQuoteQuantityArguments {
    WalletExitAcquisitionDeleveragePriceStrategy deleveragePriceStrategy;
    uint64 indexPrice;
    int64 liquidationBaseQuantity;
    uint64 liquidationQuoteQuantity;
    uint64 maintenanceMarginFraction;
    int64 liquidatingWalletTotalAccountValue;
    uint64 liquidatingWalletTotalMaintenanceMarginRequirement;
  }

  struct ValidateInsuranceFundCannotLiquidateWalletArguments {
    AcquisitionDeleverageArguments acquisitionDeleverageArguments;
    WalletExitAcquisitionDeleveragePriceStrategy deleveragePriceStrategy;
    address insuranceFundWallet;
    int64 insuranceFundWalletOutstandingFundingPayment;
    int64 liquidatingWalletTotalAccountValue;
    uint64 liquidatingWalletTotalMaintenanceMarginRequirement;
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

    int64 insuranceFundWalletOutstandingFundingPayment = Funding.loadOutstandingWalletFunding(
      insuranceFundWallet,
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
      insuranceFundWalletOutstandingFundingPayment,
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
    int64 insuranceFundWalletOutstandingFundingPayment,
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

    ValidateInsuranceFundCannotLiquidateWalletArguments memory validateInsuranceFundCannotLiquidateWalletArguments;
    validateInsuranceFundCannotLiquidateWalletArguments.acquisitionDeleverageArguments = arguments;
    validateInsuranceFundCannotLiquidateWalletArguments.deleveragePriceStrategy = deleveragePriceStrategy;
    validateInsuranceFundCannotLiquidateWalletArguments.insuranceFundWallet = insuranceFundWallet;
    validateInsuranceFundCannotLiquidateWalletArguments
      .insuranceFundWalletOutstandingFundingPayment = insuranceFundWalletOutstandingFundingPayment;
    validateInsuranceFundCannotLiquidateWalletArguments
      .liquidatingWalletTotalAccountValue = liquidatingWalletTotalAccountValue;
    validateInsuranceFundCannotLiquidateWalletArguments
      .liquidatingWalletTotalMaintenanceMarginRequirement = liquidatingWalletTotalMaintenanceMarginRequirement;

    // Do not proceed with deleverage if the Insurance Fund can acquire the wallet's positions
    _validateInsuranceFundCannotLiquidateWallet(
      validateInsuranceFundCannotLiquidateWalletArguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    ValidateDeleverageQuoteQuantityArguments memory validateDeleverageQuoteQuantityArguments;
    validateDeleverageQuoteQuantityArguments.acquisitionDeleverageArguments = arguments;
    validateDeleverageQuoteQuantityArguments.deleveragePriceStrategy = deleveragePriceStrategy;
    validateDeleverageQuoteQuantityArguments.exitFundWallet = exitFundWallet;
    validateDeleverageQuoteQuantityArguments.liquidatingWalletTotalAccountValue = liquidatingWalletTotalAccountValue;
    validateDeleverageQuoteQuantityArguments
      .liquidatingWalletTotalMaintenanceMarginRequirement = liquidatingWalletTotalMaintenanceMarginRequirement;

    // Liquidate specified position by deleveraging a counterparty position
    _validateDeleverageQuoteQuantityAndUpdatePositions(
      validateDeleverageQuoteQuantityArguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateDeleverageQuoteQuantity(
    ValidateDeleverageQuoteQuantityArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private returns (Market memory market) {
    market = Validations.loadAndValidateActiveMarket(
      arguments.acquisitionDeleverageArguments.baseAssetSymbol,
      arguments.acquisitionDeleverageArguments.liquidatingWallet,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    Balance memory balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.acquisitionDeleverageArguments.liquidatingWallet,
      market.baseAssetSymbol
    );

    ValidateExitQuoteQuantityArguments memory validateExitQuoteQuantityArguments;
    validateExitQuoteQuantityArguments.deleveragePriceStrategy = arguments.deleveragePriceStrategy;
    validateExitQuoteQuantityArguments.indexPrice = market.lastIndexPrice;
    validateExitQuoteQuantityArguments.liquidationBaseQuantity = balanceStruct.balance < 0
      ? (-1 * Math.toInt64(arguments.acquisitionDeleverageArguments.liquidationBaseQuantity))
      : Math.toInt64(arguments.acquisitionDeleverageArguments.liquidationBaseQuantity);
    validateExitQuoteQuantityArguments.liquidationQuoteQuantity = arguments
      .acquisitionDeleverageArguments
      .liquidationQuoteQuantity;
    validateExitQuoteQuantityArguments.maintenanceMarginFraction = market
      .loadMarketWithOverridesForWallet(
        arguments.acquisitionDeleverageArguments.liquidatingWallet,
        marketOverridesByBaseAssetSymbolAndWallet
      )
      .overridableFields
      .maintenanceMarginFraction;
    validateExitQuoteQuantityArguments.liquidatingWalletTotalAccountValue = arguments
      .liquidatingWalletTotalAccountValue;
    validateExitQuoteQuantityArguments.liquidatingWalletTotalMaintenanceMarginRequirement = arguments
      .liquidatingWalletTotalMaintenanceMarginRequirement;
    _validateExitQuoteQuantity(balanceStruct, validateExitQuoteQuantityArguments);
  }

  function _validateDeleverageQuoteQuantityAndUpdatePositions(
    ValidateDeleverageQuoteQuantityArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    Market memory market = _validateDeleverageQuoteQuantity(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    _updatePositionsForDeleverage(
      arguments.acquisitionDeleverageArguments,
      arguments.exitFundWallet,
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
          Math.toInt64(Math.abs(balanceStruct.balance))
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
        arguments.liquidatingWalletTotalAccountValue,
        arguments.liquidatingWalletTotalMaintenanceMarginRequirement
      );
    }
  }

  function _validateInsuranceFundCannotLiquidateWallet(
    ValidateInsuranceFundCannotLiquidateWalletArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    // Build array of union of open position base asset symbols for both liquidating and IF wallets. Result of merge
    // will already be de-duped and sorted
    string[] memory baseAssetSymbolsForInsuranceFundAndLiquidatingWallet = baseAssetSymbolsWithOpenPositionsByWallet[
      arguments.insuranceFundWallet
    ].merge(baseAssetSymbolsWithOpenPositionsByWallet[arguments.acquisitionDeleverageArguments.liquidatingWallet]);

    // Allocate struct to hold arguments needed to perform validation against IF liquidation of wallet
    IndexPriceMargin.ValidateInsuranceFundCannotLiquidateWalletArguments
      memory validateInsuranceFundCannotLiquidateWalletArguments = IndexPriceMargin
        .ValidateInsuranceFundCannotLiquidateWalletArguments(
          arguments.insuranceFundWallet,
          arguments.insuranceFundWalletOutstandingFundingPayment,
          arguments.acquisitionDeleverageArguments.liquidatingWallet,
          arguments.acquisitionDeleverageArguments.validateInsuranceFundCannotLiquidateWalletQuoteQuantities,
          new Market[](baseAssetSymbolsForInsuranceFundAndLiquidatingWallet.length)
        );

    ValidateExitQuoteQuantityArguments memory validateExitQuoteQuantityArguments;
    validateExitQuoteQuantityArguments.deleveragePriceStrategy = arguments.deleveragePriceStrategy;
    validateExitQuoteQuantityArguments.liquidatingWalletTotalAccountValue = arguments
      .liquidatingWalletTotalAccountValue;
    validateExitQuoteQuantityArguments.liquidatingWalletTotalMaintenanceMarginRequirement = arguments
      .liquidatingWalletTotalMaintenanceMarginRequirement;

    Balance memory balanceStruct;
    Market memory market;
    // Loop through open position union and populate argument struct fields
    for (uint8 i = 0; i < baseAssetSymbolsForInsuranceFundAndLiquidatingWallet.length; i++) {
      // Load market
      market = marketsByBaseAssetSymbol[baseAssetSymbolsForInsuranceFundAndLiquidatingWallet[i]];
      validateInsuranceFundCannotLiquidateWalletArguments.markets[i] = market;

      balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
        arguments.acquisitionDeleverageArguments.liquidatingWallet,
        market.baseAssetSymbol
      );

      validateExitQuoteQuantityArguments.indexPrice = market.lastIndexPrice;
      validateExitQuoteQuantityArguments.liquidationBaseQuantity = balanceStruct.balance;
      validateExitQuoteQuantityArguments.liquidationQuoteQuantity = arguments
        .acquisitionDeleverageArguments
        .validateInsuranceFundCannotLiquidateWalletQuoteQuantities[i];
      validateExitQuoteQuantityArguments.maintenanceMarginFraction = market
        .loadMarketWithOverridesForWallet(
          arguments.acquisitionDeleverageArguments.liquidatingWallet,
          marketOverridesByBaseAssetSymbolAndWallet
        )
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
