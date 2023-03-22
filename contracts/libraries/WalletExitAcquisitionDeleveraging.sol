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
import { DeleverageType, WalletExitAcquisitionDeleveragePriceStrategy } from "./Enums.sol";

library WalletExitAcquisitionDeleveraging {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
  using SortedStringSet for string[];

  struct ValidateExitQuoteQuantityArguments {
    WalletExitAcquisitionDeleveragePriceStrategy deleveragePriceStrategy;
    int64 exitAccountValue;
    uint64 indexPrice;
    uint64 liquidationBaseQuantity;
    uint64 liquidationQuoteQuantity;
    uint64 maintenanceMarginFraction;
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

    int64 exitAccountValue = IndexPriceMargin.loadExitAccountValue(
      arguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );
    uint64 liquidatingWalletTotalMaintenanceMarginRequirement = IndexPriceMargin.loadTotalMaintenanceMarginRequirement(
      arguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    // Do not proceed with deleverage if the Insurance Fund can acquire the wallet's positions
    _validateInsuranceFundCannotLiquidateWallet(
      arguments,
      exitAccountValue,
      insuranceFundWallet,
      liquidatingWalletTotalMaintenanceMarginRequirement,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol,
      walletExits
    );

    // Liquidate specified position by deleveraging a counterparty position
    _validateDeleverageQuoteQuantityAndUpdatePositions(
      arguments,
      exitAccountValue,
      exitFundWallet,
      liquidatingWalletTotalMaintenanceMarginRequirement,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol,
      walletExits
    );
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

    // Validate that the deleveraged wallet still meets its initial margin requirements
    IndexPriceMargin.validateInitialMarginRequirement(
      arguments.counterpartyWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateDeleverageQuoteQuantityAndUpdatePositions(
    AcquisitionDeleverageArguments memory arguments,
    int64 exitAccountValue,
    address exitFundWallet,
    uint64 totalMaintenanceMarginRequirement,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => WalletExit) storage walletExits
  ) private {
    Market memory market = _validateWalletExitDeleverageQuoteQuantity(
      arguments,
      exitAccountValue,
      totalMaintenanceMarginRequirement,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol,
      walletExits
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

  function _validateWalletExitDeleverageQuoteQuantity(
    AcquisitionDeleverageArguments memory arguments,
    int64 exitAccountValue,
    uint64 totalMaintenanceMarginRequirement,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => WalletExit) storage walletExits
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

    WalletExit storage walletExit = walletExits[arguments.liquidatingWallet];
    walletExit.deleveragePriceStrategy = _determineDeleveragePriceStrategy(
      walletExit.deleveragePriceStrategy,
      exitAccountValue
    );

    ValidateExitQuoteQuantityArguments memory validateExitQuoteQuantityArguments;
    validateExitQuoteQuantityArguments.deleveragePriceStrategy = walletExit.deleveragePriceStrategy;
    validateExitQuoteQuantityArguments.exitAccountValue = exitAccountValue;
    validateExitQuoteQuantityArguments.indexPrice = market.lastIndexPrice;
    validateExitQuoteQuantityArguments.liquidationBaseQuantity = arguments.liquidationBaseQuantity;
    validateExitQuoteQuantityArguments.liquidationQuoteQuantity = arguments.liquidationQuoteQuantity;
    validateExitQuoteQuantityArguments.maintenanceMarginFraction = market
      .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
      .overridableFields
      .maintenanceMarginFraction;
    validateExitQuoteQuantityArguments.totalMaintenanceMarginRequirement = totalMaintenanceMarginRequirement;
    _validateExitQuoteQuantity(balanceStruct, validateExitQuoteQuantityArguments);
  }

  function _validateInsuranceFundCannotLiquidateWallet(
    AcquisitionDeleverageArguments memory arguments,
    int64 exitAccountValue,
    address insuranceFundWallet,
    uint64 liquidatingWalletTotalMaintenanceMarginRequirement,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => WalletExit) storage walletExits
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
    validateExitQuoteQuantityArguments.deleveragePriceStrategy = _determineDeleveragePriceStrategy(
      walletExits[arguments.liquidatingWallet].deleveragePriceStrategy,
      exitAccountValue
    );
    validateExitQuoteQuantityArguments.exitAccountValue = exitAccountValue;
    validateExitQuoteQuantityArguments
      .totalMaintenanceMarginRequirement = liquidatingWalletTotalMaintenanceMarginRequirement;

    // Loop through open position union and populate argument struct fields
    for (uint8 i = 0; i < baseAssetSymbolsForInsuranceFundAndLiquidatingWallet.length; i++) {
      // Load market
      validateInsuranceFundCannotLiquidateWalletArguments.markets[i] = marketsByBaseAssetSymbol[
        baseAssetSymbolsForInsuranceFundAndLiquidatingWallet[i]
      ];

      validateExitQuoteQuantityArguments.indexPrice = marketsByBaseAssetSymbol[
        baseAssetSymbolsForInsuranceFundAndLiquidatingWallet[i]
      ].lastIndexPrice;
      validateExitQuoteQuantityArguments.liquidationQuoteQuantity = arguments
        .validateInsuranceFundCannotLiquidateWalletQuoteQuantities[i];
      validateExitQuoteQuantityArguments.maintenanceMarginFraction = validateInsuranceFundCannotLiquidateWalletArguments
        .markets[i]
        .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
        .overridableFields
        .maintenanceMarginFraction;

      _validateExitQuoteQuantity(
        balanceTracking.loadBalanceStructAndMigrateIfNeeded(
          arguments.liquidatingWallet,
          baseAssetSymbolsForInsuranceFundAndLiquidatingWallet[i]
        ),
        validateExitQuoteQuantityArguments
      );
    }

    // Argument struct is populated with validated field values, pass through to margin validation
    IndexPriceMargin.validateInsuranceFundCannotLiquidateWallet(
      validateInsuranceFundCannotLiquidateWalletArguments,
      balanceTracking,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function _validateExitQuoteQuantity(
    Balance memory balanceStruct,
    ValidateExitQuoteQuantityArguments memory arguments
  ) private pure {
    int64 liquidationBaseQuantity;
    if (arguments.liquidationBaseQuantity == 0) {
      liquidationBaseQuantity = balanceStruct.balance;
    } else {
      liquidationBaseQuantity = balanceStruct.balance < 0
        ? (-1 * int64(arguments.liquidationBaseQuantity))
        : int64(arguments.liquidationBaseQuantity);
    }

    if (arguments.deleveragePriceStrategy == WalletExitAcquisitionDeleveragePriceStrategy.ExitPrice) {
      LiquidationValidations.validateExitQuoteQuantityByExitPrice(
        // Calculate the cost basis of the base quantity being liquidated while observing signedness
        Math.multiplyPipsByFraction(
          balanceStruct.costBasis,
          liquidationBaseQuantity,
          // Position size implicitly validated non-zero by `Validations.loadAndValidateActiveMarket`
          int64(Math.abs(balanceStruct.balance))
        ),
        arguments.liquidationQuoteQuantity,
        arguments.indexPrice,
        liquidationBaseQuantity
      );
    } else {
      LiquidationValidations.validateLiquidationQuoteQuantityToClosePositions(
        arguments.indexPrice,
        arguments.liquidationQuoteQuantity,
        arguments.maintenanceMarginFraction,
        liquidationBaseQuantity,
        arguments.exitAccountValue,
        arguments.totalMaintenanceMarginRequirement
      );
    }
  }

  function _determineDeleveragePriceStrategy(
    WalletExitAcquisitionDeleveragePriceStrategy savedStrategy,
    int64 exitAccountValue
  ) private pure returns (WalletExitAcquisitionDeleveragePriceStrategy) {
    if (exitAccountValue < 0) {
      // Wallets with negative total account value must use the bankruptcy price for the remainder of exit deleveraging
      return WalletExitAcquisitionDeleveragePriceStrategy.LiquidationPrice;
    } else if (savedStrategy == WalletExitAcquisitionDeleveragePriceStrategy.None) {
      // Wallets with a positive total account value should use the exit price (worse of entry price or current entry
      // price) until deleveraging a position moves the total account value negative, at which point the bankruptcy
      // price will be used for the remainder of exit deleveraging
      return WalletExitAcquisitionDeleveragePriceStrategy.ExitPrice;
    }

    return savedStrategy;
  }
}
