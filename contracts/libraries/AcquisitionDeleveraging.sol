// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { BalanceTracking } from "./BalanceTracking.sol";
import { DeleverageType } from "./Enums.sol";
import { Funding } from "./Funding.sol";
import { IndexPriceMargin } from "./IndexPriceMargin.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Math } from "./Math.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { AcquisitionDeleverageArguments, Balance, FundingMultiplierQuartet, Market, MarketOverrides } from "./Structs.sol";

library AcquisitionDeleveraging {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
  using SortedStringSet for string[];

  struct Arguments {
    AcquisitionDeleverageArguments externalArguments;
    DeleverageType deleverageType;
    // Exchange state
    address exitFundWallet;
    address insuranceFundWallet;
  }

  // solhint-disable-next-line func-name-mixedcase
  function deleverage_delegatecall(
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    require(arguments.externalArguments.liquidatingWallet != arguments.exitFundWallet, "Cannot liquidate EF");
    require(arguments.externalArguments.liquidatingWallet != arguments.insuranceFundWallet, "Cannot liquidate IF");
    require(arguments.externalArguments.deleveragingWallet != arguments.exitFundWallet, "Cannot deleverage EF");
    require(arguments.externalArguments.deleveragingWallet != arguments.insuranceFundWallet, "Cannot deleverage IF");

    Funding.updateWalletFunding(
      arguments.externalArguments.deleveragingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.updateWalletFunding(
      arguments.externalArguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    _validateArgumentsAndDeleverage(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateArgumentsAndDeleverage(
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    require(
      balanceTracking.loadBalanceAndMigrateIfNeeded(
        arguments.externalArguments.liquidatingWallet,
        arguments.externalArguments.baseAssetSymbol
      ) != 0,
      "No open position in market"
    );

    // Validate that the liquidating account has fallen below margin requirements
    (
      int64 liquidatingWalletTotalAccountValue,
      uint64 liquidatingWalletTotalMaintenanceMarginRequirement
    ) = IndexPriceMargin.loadTotalAccountValueAndMaintenanceMarginRequirement(
        arguments.externalArguments.liquidatingWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    if (arguments.deleverageType == DeleverageType.WalletInMaintenance) {
      require(
        liquidatingWalletTotalAccountValue < int64(liquidatingWalletTotalMaintenanceMarginRequirement),
        "Maintenance margin requirement met"
      );
    }

    // Do not proceed with deleverage if the Insurance Fund can acquire the wallet's positions
    _validateInsuranceFundCannotLiquidateWallet(
      arguments,
      liquidatingWalletTotalAccountValue,
      liquidatingWalletTotalMaintenanceMarginRequirement,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    // Liquidate specified position by deleveraging a counterparty position
    _validateQuoteQuantityAndDeleveragePosition(
      arguments,
      liquidatingWalletTotalAccountValue,
      liquidatingWalletTotalMaintenanceMarginRequirement,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateInsuranceFundCannotLiquidateWallet(
    Arguments memory arguments,
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
      arguments.insuranceFundWallet
    ].merge(baseAssetSymbolsWithOpenPositionsByWallet[arguments.externalArguments.liquidatingWallet]);

    // Allocate struct to hold arguments needed to perform validation against IF liquidation of wallet
    IndexPriceMargin.ValidateInsuranceFundCannotLiquidateWalletArguments memory loadArguments = IndexPriceMargin
      .ValidateInsuranceFundCannotLiquidateWalletArguments(
        arguments.insuranceFundWallet,
        arguments.externalArguments.liquidatingWallet,
        arguments.externalArguments.validateInsuranceFundCannotLiquidateWalletQuoteQuantities,
        new Market[](baseAssetSymbolsForInsuranceFundAndLiquidatingWallet.length)
      );

    // Loop through open position union and populate argument struct fields
    for (uint8 i = 0; i < baseAssetSymbolsForInsuranceFundAndLiquidatingWallet.length; i++) {
      // Load market
      loadArguments.markets[i] = marketsByBaseAssetSymbol[baseAssetSymbolsForInsuranceFundAndLiquidatingWallet[i]];

      // Validate provided liquidation quote quantity
      if (arguments.deleverageType == DeleverageType.WalletInMaintenance) {
        LiquidationValidations.validateLiquidationQuoteQuantityToClosePositions(
          arguments.externalArguments.validateInsuranceFundCannotLiquidateWalletQuoteQuantities[i],
          loadArguments
            .markets[i]
            .loadMarketWithOverridesForWallet(
              arguments.externalArguments.liquidatingWallet,
              marketOverridesByBaseAssetSymbolAndWallet
            )
            .overridableFields
            .maintenanceMarginFraction,
          loadArguments.markets[i].lastIndexPrice,
          balanceTracking.loadBalanceAndMigrateIfNeeded(
            arguments.externalArguments.liquidatingWallet,
            baseAssetSymbolsForInsuranceFundAndLiquidatingWallet[i]
          ),
          liquidatingWalletTotalAccountValue,
          liquidatingWalletTotalMaintenanceMarginRequirement
        );
      } else {
        // DeleverageType.WalletExited
        Balance storage balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
          arguments.externalArguments.liquidatingWallet,
          baseAssetSymbolsForInsuranceFundAndLiquidatingWallet[i]
        );
        LiquidationValidations.validateExitQuoteQuantity(
          balanceStruct.costBasis,
          arguments.externalArguments.validateInsuranceFundCannotLiquidateWalletQuoteQuantities[i],
          loadArguments.markets[i].lastIndexPrice,
          loadArguments
            .markets[i]
            .loadMarketWithOverridesForWallet(
              arguments.externalArguments.liquidatingWallet,
              marketOverridesByBaseAssetSymbolAndWallet
            )
            .overridableFields
            .maintenanceMarginFraction,
          balanceStruct.balance,
          liquidatingWalletTotalAccountValue,
          liquidatingWalletTotalMaintenanceMarginRequirement
        );
      }
    }

    // Argument struct is populated with validated field values, pass through to margin validation
    IndexPriceMargin.validateInsuranceFundCannotLiquidateWallet(
      loadArguments,
      balanceTracking,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function _validateQuoteQuantity(
    Arguments memory arguments,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private returns (Market memory) {
    Market memory market = Validations.loadAndValidateMarket(
      arguments.externalArguments.baseAssetSymbol,
      arguments.externalArguments.liquidatingWallet,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    Balance memory balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.externalArguments.liquidatingWallet,
      market.baseAssetSymbol
    );

    if (arguments.deleverageType == DeleverageType.WalletInMaintenance) {
      LiquidationValidations.validateLiquidationQuoteQuantityToClosePositions(
        arguments.externalArguments.liquidationQuoteQuantity,
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
      // DeleverageType.WalletExited
      LiquidationValidations.validateExitQuoteQuantity(
        // Calculate the cost basis of the base quantity being liquidated while observing signedness
        Math.multiplyPipsByFraction(
          balanceStruct.costBasis,
          int64(arguments.externalArguments.liquidationBaseQuantity),
          int64(Math.abs(balanceStruct.balance))
        ),
        arguments.externalArguments.liquidationQuoteQuantity,
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

    return market;
  }

  function _validateQuoteQuantityAndDeleveragePosition(
    Arguments memory arguments,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    Market memory market = _validateQuoteQuantity(
      arguments,
      totalAccountValue,
      totalMaintenanceMarginRequirement,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    balanceTracking.updatePositionForDeleverage(
      arguments.externalArguments.liquidationBaseQuantity,
      arguments.externalArguments.deleveragingWallet,
      arguments.externalArguments.liquidatingWallet,
      market,
      arguments.externalArguments.liquidationQuoteQuantity,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    // Validate that the deleveraged wallet still meets its initial margin requirements
    IndexPriceMargin.loadAndValidateTotalAccountValueAndInitialMarginRequirement(
      arguments.externalArguments.deleveragingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }
}
