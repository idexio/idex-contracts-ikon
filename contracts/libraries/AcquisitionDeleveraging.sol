// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { DeleverageType } from "./Enums.sol";
import { Deleveraging } from "./Deleveraging.sol";
import { ExitFund } from "./ExitFund.sol";
import { Funding } from "./Funding.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { NonMutatingMargin } from "./NonMutatingMargin.sol";
import { Math } from "./Math.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { MutatingMargin } from "./MutatingMargin.sol";
import { NonMutatingMargin } from "./NonMutatingMargin.sol";
import { String } from "./String.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { Balance, FundingMultiplierQuartet, IndexPrice, Market, MarketOverrides } from "./Structs.sol";

library AcquisitionDeleveraging {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
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
    require(arguments.liquidatingWallet != arguments.exitFundWallet, "Cannot liquidate EF");
    require(arguments.liquidatingWallet != arguments.insuranceFundWallet, "Cannot liquidate IF");
    require(arguments.deleveragingWallet != arguments.exitFundWallet, "Cannot deleverage EF");
    require(arguments.deleveragingWallet != arguments.insuranceFundWallet, "Cannot deleverage IF");

    Funding.updateWalletFunding(
      arguments.deleveragingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.updateWalletFunding(
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
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    require(
      balanceTracking.loadBalanceAndMigrateIfNeeded(arguments.liquidatingWallet, arguments.baseAssetSymbol) != 0,
      "No open position in market"
    );

    // Validate that the liquidating account has fallen below margin requirements
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

  function _validateQuoteQuantityAndDeleveragePosition(
    Arguments memory arguments,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    (Market memory market, IndexPrice memory indexPrice) = Deleveraging.loadMarketAndIndexPrice(
      arguments.baseAssetSymbol,
      arguments.liquidatingWallet,
      arguments.liquidatingWalletIndexPrices,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );
    Validations.validateIndexPrice(indexPrice, arguments.indexPriceCollectionServiceWallets, market);

    Balance storage balance = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.liquidatingWallet,
      market.baseAssetSymbol
    );

    if (arguments.deleverageType == DeleverageType.WalletInMaintenance) {
      LiquidationValidations.validateLiquidationQuoteQuantityToClosePositions(
        arguments.liquidationQuoteQuantity,
        market
          .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maintenanceMarginFraction,
        indexPrice.price,
        balance.balance,
        totalAccountValue,
        totalMaintenanceMarginRequirement
      );
    } else {
      // DeleverageType.WalletExited
      LiquidationValidations.validateExitQuoteQuantity(
        Math.multiplyPipsByFraction(balance.costBasis, -1 * arguments.liquidationBaseQuantity, balance.balance),
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
    MutatingMargin.loadAndValidateTotalAccountValueAndInitialMarginRequirementAndUpdateLastIndexPrice(
      NonMutatingMargin.LoadArguments(
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
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.insuranceFundWallet].merge(
      baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet]
    );

    NonMutatingMargin.ValidateInsuranceFundCannotLiquidateWalletArguments memory loadArguments = NonMutatingMargin
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
            .overridableFields
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
          baseAssetSymbols[i]
        );
        LiquidationValidations.validateExitQuoteQuantity(
          balance.costBasis,
          arguments.liquidationQuoteQuantities[i],
          loadArguments.indexPrices[i],
          balance.balance,
          liquidatingWalletTotalAccountValue
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
