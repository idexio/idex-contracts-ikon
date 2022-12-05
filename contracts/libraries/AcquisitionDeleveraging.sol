// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { DeleverageType } from "./Enums.sol";
import { ExitFund } from "./ExitFund.sol";
import { Funding } from "./Funding.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { Margin } from "./Margin.sol";
import { Math } from "./Math.sol";
import { MarketOverrides } from "./MarketOverrides.sol";
import { String } from "./String.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { Balance, FundingMultiplierQuartet, Market, IndexPrice } from "./Structs.sol";

library AcquisitionDeleveraging {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketOverrides for Market;
  using SortedStringSet for string[];

  struct Arguments {
    // External arguments
    DeleverageType deleverageType;
    string baseAssetSymbol;
    address deleveragingWallet;
    address liquidatingWallet;
    int64[] liquidationQuoteQuantities; // For all open positions
    int64 liquidationBaseQuantity; // For the position being liquidated
    int64 liquidationQuoteQuantity; // For the position being liquidated
    IndexPrice[] deleveragingWalletIndexPrices; // After acquiring liquidating positions
    IndexPrice[] insuranceFundIndexPrices; // After acquiring liquidating positions
    IndexPrice[] liquidatingWalletIndexPrices; // Before liquidation
    // Exchange state
    address insuranceFundWallet;
    address[] indexPriceCollectionServiceWallets;
  }

  function deleverage(
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    Funding.updateWalletFundingInternal(
      arguments.deleveragingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.updateWalletFundingInternal(
      arguments.liquidatingWallet,
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
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateArgumentsAndDeleverage(
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    // Validate that the liquidating account has fallen below margin requirements
    (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) = Margin
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
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _loadMarketAndIndexPrice(
    Arguments memory arguments,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (Market memory market, IndexPrice memory indexPrice) {
    market = marketsByBaseAssetSymbol[arguments.baseAssetSymbol];

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      if (String.isEqual(baseAssetSymbols[i], arguments.baseAssetSymbol)) {
        indexPrice = arguments.liquidatingWalletIndexPrices[i];
        break;
      }
    }

    require(market.exists && market.isActive, "No active market found");
  }

  function _validateQuoteQuantityAndDeleveragePosition(
    Arguments memory arguments,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    (Market memory market, IndexPrice memory indexPrice) = _loadMarketAndIndexPrice(
      arguments,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );
    Validations.validateIndexPrice(indexPrice, market, arguments.indexPriceCollectionServiceWallets);

    Balance storage balance = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.liquidatingWallet,
      market.baseAssetSymbol
    );

    if (arguments.deleverageType == DeleverageType.WalletInMaintenance) {
      LiquidationValidations.validateLiquidationQuoteQuantityToClosePositions(
        arguments.liquidationQuoteQuantity,
        market
          .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .maintenanceMarginFraction,
        indexPrice.price,
        balance.balance,
        totalAccountValue,
        totalMaintenanceMarginRequirement
      );
    } else {
      // DeleverageType.WalletExited
      LiquidationValidations.validateExitQuoteQuantity(
        Math.multiplyPipsByFraction(balance.costBasis, arguments.liquidationBaseQuantity, balance.balance),
        arguments.liquidationQuoteQuantity,
        indexPrice.price,
        balance.balance,
        totalAccountValue
      );
    }

    balanceTracking.updatePositionForDeleverage(
      arguments.liquidationBaseQuantity,
      arguments.deleveragingWallet,
      arguments.liquidatingWallet,
      market,
      arguments.liquidationQuoteQuantity,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    // Validate that the deleveraged wallet still meets its initial margin requirements
    Margin.loadAndValidateTotalAccountValueAndInitialMarginRequirement(
      Margin.LoadArguments(
        arguments.deleveragingWallet,
        arguments.deleveragingWalletIndexPrices,
        arguments.indexPriceCollectionServiceWallets
      ),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
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
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.insuranceFundWallet].merge(
      baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet]
    );

    Margin.ValidateInsuranceFundCannotLiquidateWalletArguments memory loadArguments = Margin
      .ValidateInsuranceFundCannotLiquidateWalletArguments(
        arguments.insuranceFundWallet,
        arguments.liquidatingWallet,
        arguments.liquidationQuoteQuantities,
        new Market[](baseAssetSymbols.length),
        new uint64[](baseAssetSymbols.length),
        arguments.indexPriceCollectionServiceWallets
      );

    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      // Load market and index price for symbol
      loadArguments.markets[i] = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      Validations.validateAndUpdateIndexPrice(
        arguments.insuranceFundIndexPrices[i],
        marketsByBaseAssetSymbol[baseAssetSymbols[i]],
        arguments.indexPriceCollectionServiceWallets
      );
      loadArguments.indexPrices[i] = arguments.insuranceFundIndexPrices[i].price;

      // Validate provided liquidation quote quantity
      if (arguments.deleverageType == DeleverageType.WalletInMaintenance) {
        LiquidationValidations.validateLiquidationQuoteQuantityToClosePositions(
          arguments.liquidationQuoteQuantities[i],
          loadArguments
            .markets[i]
            .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
            .maintenanceMarginFraction,
          loadArguments.indexPrices[i],
          balanceTracking.loadBalanceAndMigrateIfNeeded(arguments.liquidatingWallet, baseAssetSymbols[i]),
          liquidatingWalletTotalAccountValue,
          liquidatingWalletTotalMaintenanceMarginRequirement
        );
      } else {
        // DeleverageType.WalletExited
        Balance storage balance = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
          arguments.liquidatingWallet,
          loadArguments.markets[i].baseAssetSymbol
        );
        LiquidationValidations.validateExitQuoteQuantity(
          Math.multiplyPipsByFraction(balance.costBasis, arguments.liquidationBaseQuantity, balance.balance),
          arguments.liquidationQuoteQuantities[i],
          loadArguments.indexPrices[i],
          balanceTracking.loadBalanceAndMigrateIfNeeded(arguments.liquidatingWallet, baseAssetSymbols[i]),
          liquidatingWalletTotalAccountValue
        );
      }
    }

    Margin.validateInsuranceFundCannotLiquidateWallet(
      loadArguments,
      balanceTracking,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }
}
