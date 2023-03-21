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

library AcquisitionDeleveraging {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
  using SortedStringSet for string[];

  // solhint-disable-next-line func-name-mixedcase
  function deleverage_delegatecall(
    AcquisitionDeleverageArguments memory arguments,
    DeleverageType deleverageType,
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
    require(arguments.liquidatingWallet != exitFundWallet, "Cannot liquidate EF");
    require(arguments.liquidatingWallet != insuranceFundWallet, "Cannot liquidate IF");
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
      deleverageType,
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
    DeleverageType deleverageType,
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

    // Validate that the liquidating account has fallen below margin requirements
    (
      int64 liquidatingWalletTotalAccountValue,
      uint64 liquidatingWalletTotalMaintenanceMarginRequirement
    ) = IndexPriceMargin.loadTotalAccountValueAndMaintenanceMarginRequirement(
        arguments.liquidatingWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    if (deleverageType == DeleverageType.WalletInMaintenanceAcquisition) {
      require(
        liquidatingWalletTotalAccountValue < int64(liquidatingWalletTotalMaintenanceMarginRequirement),
        "Maintenance margin requirement met"
      );
    }

    // Do not proceed with deleverage if the Insurance Fund can acquire the wallet's positions
    _validateInsuranceFundCannotLiquidateWallet(
      arguments,
      deleverageType,
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
      deleverageType,
      exitFundWallet,
      liquidatingWalletTotalAccountValue,
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

  function _validateDeleverageQuoteQuantity(
    AcquisitionDeleverageArguments memory arguments,
    DeleverageType deleverageType,
    int64 totalAccountValue,
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

    if (deleverageType == DeleverageType.WalletInMaintenanceAcquisition) {
      LiquidationValidations.validateLiquidationQuoteQuantityToClosePositions(
        market.lastIndexPrice,
        arguments.liquidationQuoteQuantity,
        market
          .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maintenanceMarginFraction,
        balanceStruct.balance < 0
          ? (-1 * int64(arguments.liquidationBaseQuantity))
          : int64(arguments.liquidationBaseQuantity),
        totalAccountValue,
        totalMaintenanceMarginRequirement
      );
    } else {
      // DeleverageType.WalletExitAcquisition
      WalletExit storage walletExit = walletExits[arguments.liquidatingWallet];

      if (totalAccountValue < 0) {
        // Wallets with negative total account value must use the bankruptcy price for the remainder of exit deleveraging
        walletExit.deleveragePriceStrategy = WalletExitAcquisitionDeleveragePriceStrategy.PriceToClosePositions;
      } else if (walletExit.deleveragePriceStrategy == WalletExitAcquisitionDeleveragePriceStrategy.None) {
        // Wallets with a positive total account value should use the exit price (worse of entry price or current entry
        // price) until deleveraging a position moves the total account value negative, at which point the bankruptcy
        // price will be used for the remainder of exit deleveraging
        walletExit.deleveragePriceStrategy = WalletExitAcquisitionDeleveragePriceStrategy.WorseOfEntryOrCurrentPrice;
      }

      if (
        walletExit.deleveragePriceStrategy == WalletExitAcquisitionDeleveragePriceStrategy.WorseOfEntryOrCurrentPrice
      ) {
        LiquidationValidations.validateExitQuoteQuantityByWorseOfEntryOrCurrentPrice(
          // Calculate the cost basis of the base quantity being liquidated while observing signedness
          Math.multiplyPipsByFraction(
            balanceStruct.costBasis,
            int64(arguments.liquidationBaseQuantity),
            // Position size implicitly validated non-zero by `Validations.loadAndValidateActiveMarket`
            int64(Math.abs(balanceStruct.balance))
          ),
          arguments.liquidationQuoteQuantity,
          market.lastIndexPrice,
          balanceStruct.balance < 0
            ? (-1 * int64(arguments.liquidationBaseQuantity))
            : int64(arguments.liquidationBaseQuantity)
        );
      } else {
        LiquidationValidations.validateLiquidationQuoteQuantityToClosePositions(
          market.lastIndexPrice,
          arguments.liquidationQuoteQuantity,
          market
            .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
            .overridableFields
            .maintenanceMarginFraction,
          balanceStruct.balance < 0
            ? (-1 * int64(arguments.liquidationBaseQuantity))
            : int64(arguments.liquidationBaseQuantity),
          totalAccountValue,
          totalMaintenanceMarginRequirement
        );
      }
    }
  }

  function _validateDeleverageQuoteQuantityAndUpdatePositions(
    AcquisitionDeleverageArguments memory arguments,
    DeleverageType deleverageType,
    address exitFundWallet,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => WalletExit) storage walletExits
  ) private {
    Market memory market = _validateDeleverageQuoteQuantity(
      arguments,
      deleverageType,
      totalAccountValue,
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

  function _validateInsuranceFundCannotLiquidateWallet(
    AcquisitionDeleverageArguments memory arguments,
    DeleverageType deleverageType,
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
    IndexPriceMargin.ValidateInsuranceFundCannotLiquidateWalletArguments memory loadArguments = IndexPriceMargin
      .ValidateInsuranceFundCannotLiquidateWalletArguments(
        insuranceFundWallet,
        arguments.liquidatingWallet,
        arguments.validateInsuranceFundCannotLiquidateWalletQuoteQuantities,
        new Market[](baseAssetSymbolsForInsuranceFundAndLiquidatingWallet.length)
      );

    // Loop through open position union and populate argument struct fields
    for (uint8 i = 0; i < baseAssetSymbolsForInsuranceFundAndLiquidatingWallet.length; i++) {
      // Load market
      loadArguments.markets[i] = marketsByBaseAssetSymbol[baseAssetSymbolsForInsuranceFundAndLiquidatingWallet[i]];

      _validateInsuranceFundLiquidationQuoteQuantityForPosition(
        arguments,
        baseAssetSymbolsForInsuranceFundAndLiquidatingWallet,
        deleverageType,
        i,
        liquidatingWalletTotalAccountValue,
        liquidatingWalletTotalMaintenanceMarginRequirement,
        loadArguments,
        balanceTracking,
        marketOverridesByBaseAssetSymbolAndWallet
      );
    }

    // Argument struct is populated with validated field values, pass through to margin validation
    IndexPriceMargin.validateInsuranceFundCannotLiquidateWallet(
      loadArguments,
      balanceTracking,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function _validateInsuranceFundLiquidationQuoteQuantityForPosition(
    AcquisitionDeleverageArguments memory arguments,
    string[] memory baseAssetSymbolsForInsuranceFundAndLiquidatingWallet,
    DeleverageType deleverageType,
    uint8 index,
    int64 liquidatingWalletTotalAccountValue,
    uint64 liquidatingWalletTotalMaintenanceMarginRequirement,
    IndexPriceMargin.ValidateInsuranceFundCannotLiquidateWalletArguments memory loadArguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    // Validate provided liquidation quote quantity
    if (deleverageType == DeleverageType.WalletInMaintenanceAcquisition) {
      LiquidationValidations.validateLiquidationQuoteQuantityToClosePositions(
        loadArguments.markets[index].lastIndexPrice,
        arguments.validateInsuranceFundCannotLiquidateWalletQuoteQuantities[index],
        loadArguments
          .markets[index]
          .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maintenanceMarginFraction,
        balanceTracking.loadBalanceAndMigrateIfNeeded(
          arguments.liquidatingWallet,
          baseAssetSymbolsForInsuranceFundAndLiquidatingWallet[index]
        ),
        liquidatingWalletTotalAccountValue,
        liquidatingWalletTotalMaintenanceMarginRequirement
      );
    } else {
      // DeleverageType.WalletExitAcquisition
      Balance storage balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
        arguments.liquidatingWallet,
        baseAssetSymbolsForInsuranceFundAndLiquidatingWallet[index]
      );
      LiquidationValidations.validateExitQuoteQuantity(
        balanceStruct.costBasis,
        arguments.validateInsuranceFundCannotLiquidateWalletQuoteQuantities[index],
        loadArguments.markets[index].lastIndexPrice,
        loadArguments
          .markets[index]
          .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maintenanceMarginFraction,
        balanceStruct.balance,
        liquidatingWalletTotalAccountValue,
        liquidatingWalletTotalMaintenanceMarginRequirement
      );
    }
  }
}
