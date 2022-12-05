// SPDX-License-Identifier: LGPL-3.0-only

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Math } from "./Math.sol";
import { NonMutatingMargin } from "./NonMutatingMargin.sol";
import { Validations } from "./Validations.sol";
import { IndexPrice, Market, MarketOverrides } from "./Structs.sol";

pragma solidity 0.8.17;

library MutatingMargin {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;

  struct ValidateInsuranceFundCannotLiquidateWalletArguments {
    address insuranceFundWallet;
    address liquidatingWallet;
    int64[] liquidationQuoteQuantities;
    Market[] markets;
    uint64[] indexPrices;
    address[] indexPriceCollectionServiceWallets;
  }

  function isInitialMarginRequirementMetAndUpdateLastIndexPrice(
    NonMutatingMargin.LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal returns (bool) {
    return
      NonMutatingMargin.loadTotalAccountValueInternal(
        arguments,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      ) >=
      int64(
        loadTotalInitialMarginRequirementAndUpdateLastIndexPrice(
          arguments,
          balanceTracking,
          baseAssetSymbolsWithOpenPositionsByWallet,
          marketOverridesByBaseAssetSymbolAndWallet,
          marketsByBaseAssetSymbol
        )
      );
  }

  function loadAndValidateTotalAccountValueAndInitialMarginRequirementAndUpdateLastIndexPrice(
    NonMutatingMargin.LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal returns (int64 totalAccountValue, uint64 totalInitialMarginRequirement) {
    totalAccountValue = NonMutatingMargin.loadTotalAccountValueInternal(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    totalInitialMarginRequirement = loadTotalInitialMarginRequirementAndUpdateLastIndexPrice(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    require(totalAccountValue >= int64(totalInitialMarginRequirement), "Initial margin requirement not met");

    return (totalAccountValue, totalInitialMarginRequirement);
  }

  function loadTotalAccountValueAndMaintenanceMarginRequirementAndUpdateLastIndexPrice(
    NonMutatingMargin.LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal returns (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) {
    totalAccountValue = NonMutatingMargin.loadTotalAccountValueInternal(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    totalMaintenanceMarginRequirement = loadTotalMaintenanceMarginRequirementAndUpdateLastIndexPrice(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function loadTotalInitialMarginRequirementAndUpdateLastIndexPrice(
    NonMutatingMargin.LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal returns (uint64 initialMarginRequirement) {
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      (Market storage market, IndexPrice memory indexPrice) = (
        marketsByBaseAssetSymbol[baseAssetSymbols[i]],
        arguments.indexPrices[i]
      );

      initialMarginRequirement += _loadMarginRequirementAndUpdateLastIndexPrice(
        arguments,
        indexPrice,
        market.loadInitialMarginFractionForWallet(
          balanceTracking.loadBalanceFromMigrationSourceIfNeeded(arguments.wallet, market.baseAssetSymbol),
          arguments.wallet,
          marketOverridesByBaseAssetSymbolAndWallet
        ),
        market,
        balanceTracking
      );
    }
  }

  function loadTotalMaintenanceMarginRequirementAndUpdateLastIndexPrice(
    NonMutatingMargin.LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal returns (uint64 maintenanceMarginRequirement) {
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      (Market storage market, IndexPrice memory indexPrice) = (
        marketsByBaseAssetSymbol[baseAssetSymbols[i]],
        arguments.indexPrices[i]
      );

      maintenanceMarginRequirement += _loadMarginRequirementAndUpdateLastIndexPrice(
        arguments,
        indexPrice,
        market
          .loadMarketWithOverridesForWallet(arguments.wallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maintenanceMarginFraction,
        market,
        balanceTracking
      );
    }
  }

  function _loadMarginRequirementAndUpdateLastIndexPrice(
    NonMutatingMargin.LoadArguments memory arguments,
    IndexPrice memory indexPrice,
    uint64 marginFraction,
    Market storage market,
    BalanceTracking.Storage storage balanceTracking
  ) private returns (uint64) {
    Validations.validateAndUpdateIndexPrice(indexPrice, market, arguments.indexPriceCollectionServiceWallets);

    return
      Math.abs(
        Math.multiplyPipsByFraction(
          Math.multiplyPipsByFraction(
            balanceTracking.loadBalanceFromMigrationSourceIfNeeded(arguments.wallet, market.baseAssetSymbol),
            int64(indexPrice.price),
            int64(Constants.PIP_PRICE_MULTIPLIER)
          ),
          int64(marginFraction),
          int64(Constants.PIP_PRICE_MULTIPLIER)
        )
      );
  }
}
