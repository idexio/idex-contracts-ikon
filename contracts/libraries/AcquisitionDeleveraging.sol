// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { BalanceTracking } from "./BalanceTracking.sol";
import { DeleverageType } from "./Enums.sol";
import { Deleveraging } from "./Deleveraging.sol";
import { Funding } from "./Funding.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { Math } from "./Math.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { MutatingMargin } from "./MutatingMargin.sol";
import { NonMutatingMargin } from "./NonMutatingMargin.sol";
import { String } from "./String.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { AcquisitionDeleverageArguments, Balance, FundingMultiplierQuartet, IndexPrice, Market, MarketOverrides } from "./Structs.sol";

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
    address[] indexPriceCollectionServiceWallets;
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
    (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) = MutatingMargin
      .loadTotalAccountValueAndMaintenanceMarginRequirementAndUpdateLastIndexPrice(
        NonMutatingMargin.LoadArguments(
          arguments.externalArguments.liquidatingWallet,
          arguments.externalArguments.liquidatingWalletIndexPrices,
          arguments.indexPriceCollectionServiceWallets
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    if (arguments.deleverageType == DeleverageType.WalletInMaintenance) {
      require(totalAccountValue < int64(totalMaintenanceMarginRequirement), "Maintenance margin requirement met");
    }

    // Do not proceed with deleverage if the Insurance Fund can acquire the wallet's positions
    _validateInsuranceFundCannotLiquidateWallet(
      arguments,
      totalAccountValue,
      totalMaintenanceMarginRequirement,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    // Liquidate specified position by deleveraging a counterparty position at the liquidating wallet's bankruptcy price
    _validateQuoteQuantityAndDeleveragePosition(
      arguments,
      totalAccountValue,
      totalMaintenanceMarginRequirement,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
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
    MutatingMargin.loadAndValidateTotalAccountValueAndInitialMarginRequirementAndUpdateLastIndexPrice(
      NonMutatingMargin.LoadArguments(
        arguments.externalArguments.deleveragingWallet,
        arguments.externalArguments.deleveragingWalletIndexPrices,
        arguments.indexPriceCollectionServiceWallets
      ),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
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
    (Market memory market, IndexPrice memory indexPrice) = Deleveraging.loadMarketAndIndexPrice(
      arguments.externalArguments.baseAssetSymbol,
      arguments.externalArguments.liquidatingWallet,
      arguments.externalArguments.liquidatingWalletIndexPrices,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );
    Validations.validateIndexPrice(indexPrice, arguments.indexPriceCollectionServiceWallets, market);

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
        indexPrice.price,
        balanceStruct.balance,
        totalAccountValue,
        totalMaintenanceMarginRequirement
      );
    } else {
      // DeleverageType.WalletExited
      LiquidationValidations.validateExitQuoteQuantity(
        Math.multiplyPipsByFraction(
          balanceStruct.costBasis,
          int64(arguments.externalArguments.liquidationBaseQuantity),
          balanceStruct.balance
        ),
        arguments.externalArguments.liquidationQuoteQuantity,
        indexPrice.price,
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

  function _validateInsuranceFundCannotLiquidateWallet(
    Arguments memory arguments,
    int64 liquidatingWalletTotalAccountValue,
    uint64 liquidatingWalletTotalMaintenanceMarginRequirement,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.insuranceFundWallet].merge(
      baseAssetSymbolsWithOpenPositionsByWallet[arguments.externalArguments.liquidatingWallet]
    );

    NonMutatingMargin.ValidateInsuranceFundCannotLiquidateWalletArguments memory loadArguments = NonMutatingMargin
      .ValidateInsuranceFundCannotLiquidateWalletArguments(
        arguments.insuranceFundWallet,
        arguments.externalArguments.liquidatingWallet,
        arguments.externalArguments.liquidationQuoteQuantities,
        new Market[](baseAssetSymbols.length),
        new uint64[](baseAssetSymbols.length),
        arguments.indexPriceCollectionServiceWallets
      );

    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      // Load market and index price for symbol
      loadArguments.markets[i] = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      Validations.validateAndUpdateIndexPrice(
        arguments.externalArguments.insuranceFundIndexPrices[i],
        marketsByBaseAssetSymbol[baseAssetSymbols[i]],
        arguments.indexPriceCollectionServiceWallets
      );
      loadArguments.indexPrices[i] = arguments.externalArguments.insuranceFundIndexPrices[i].price;

      // Validate provided liquidation quote quantity
      if (arguments.deleverageType == DeleverageType.WalletInMaintenance) {
        LiquidationValidations.validateLiquidationQuoteQuantityToClosePositions(
          arguments.externalArguments.liquidationQuoteQuantities[i],
          loadArguments
            .markets[i]
            .loadMarketWithOverridesForWallet(
              arguments.externalArguments.liquidatingWallet,
              marketOverridesByBaseAssetSymbolAndWallet
            )
            .overridableFields
            .maintenanceMarginFraction,
          loadArguments.indexPrices[i],
          balanceTracking.loadBalanceAndMigrateIfNeeded(
            arguments.externalArguments.liquidatingWallet,
            baseAssetSymbols[i]
          ),
          liquidatingWalletTotalAccountValue,
          liquidatingWalletTotalMaintenanceMarginRequirement
        );
      } else {
        // DeleverageType.WalletExited
        Balance storage balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
          arguments.externalArguments.liquidatingWallet,
          baseAssetSymbols[i]
        );
        LiquidationValidations.validateExitQuoteQuantity(
          balanceStruct.costBasis,
          arguments.externalArguments.liquidationQuoteQuantities[i],
          loadArguments.indexPrices[i],
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

    NonMutatingMargin.validateInsuranceFundCannotLiquidateWallet(
      loadArguments,
      balanceTracking,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }
}
