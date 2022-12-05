// SPDX-License-Identifier: LGPL-3.0-only

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { MarketOverrides } from "./MarketOverrides.sol";
import { Math } from "./Math.sol";
import { Validations } from "./Validations.sol";
import { Balance, Market, IndexPrice } from "./Structs.sol";

pragma solidity 0.8.17;

library NonMutatingMargin {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
  using MarketOverrides for Market;

  struct LoadArguments {
    address wallet;
    IndexPrice[] indexPrices;
    address[] indexPriceCollectionServiceWallets;
  }

  struct ValidateInsuranceFundCannotLiquidateWalletArguments {
    address insuranceFundWallet;
    address liquidatingWallet;
    int64[] liquidationQuoteQuantities;
    Market[] markets;
    uint64[] indexPrices;
    address[] indexPriceCollectionServiceWallets;
  }

  function loadTotalAccountValue(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (int64) {
    return
      loadTotalAccountValueInternal(
        arguments,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      );
  }

  function loadTotalInitialMarginRequirement(
    address wallet,
    IndexPrice[] memory indexPrices,
    address[] memory indexPriceCollectionServiceWallets,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (uint64 initialMarginRequirement) {
    return
      loadTotalInitialMarginRequirementInternal(
        wallet,
        indexPrices,
        indexPriceCollectionServiceWallets,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
  }

  function loadTotalMaintenanceMarginRequirement(
    address wallet,
    IndexPrice[] memory indexPrices,
    address[] memory indexPriceCollectionServiceWallets,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (uint64 maintenanceMarginRequirement) {
    return
      loadTotalMaintenanceMarginRequirementInternal(
        wallet,
        indexPrices,
        indexPriceCollectionServiceWallets,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
  }

  function loadTotalAccountValueInternal(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64) {
    int64 totalAccountValue = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
      arguments.wallet,
      Constants.QUOTE_ASSET_SYMBOL
    );

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      Market memory market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      Validations.validateIndexPrice(arguments.indexPrices[i], arguments.indexPriceCollectionServiceWallets, market);

      totalAccountValue += Math.multiplyPipsByFraction(
        balanceTracking.loadBalanceFromMigrationSourceIfNeeded(arguments.wallet, market.baseAssetSymbol),
        int64(arguments.indexPrices[i].price),
        int64(Constants.PIP_PRICE_MULTIPLIER)
      );
    }

    return totalAccountValue;
  }

  function loadTotalInitialMarginRequirementInternal(
    address wallet,
    IndexPrice[] memory indexPrices,
    address[] memory indexPriceCollectionServiceWallets,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (uint64 initialMarginRequirement) {
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      (Market memory market, IndexPrice memory indexPrice) = (
        marketsByBaseAssetSymbol[baseAssetSymbols[i]],
        indexPrices[i]
      );

      initialMarginRequirement += _loadMarginRequirement(
        indexPrice,
        indexPriceCollectionServiceWallets,
        market.loadInitialMarginFractionForWallet(
          balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol),
          wallet,
          marketOverridesByBaseAssetSymbolAndWallet
        ),
        market,
        wallet,
        balanceTracking
      );
    }
  }

  function loadTotalMaintenanceMarginRequirementInternal(
    address wallet,
    IndexPrice[] memory indexPrices,
    address[] memory indexPriceCollectionServiceWallets,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (uint64 maintenanceMarginRequirement) {
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      (Market memory market, IndexPrice memory indexPrice) = (
        marketsByBaseAssetSymbol[baseAssetSymbols[i]],
        indexPrices[i]
      );

      maintenanceMarginRequirement += _loadMarginRequirement(
        indexPrice,
        indexPriceCollectionServiceWallets,
        market
          .loadMarketWithOverridesForWallet(wallet, marketOverridesByBaseAssetSymbolAndWallet)
          .maintenanceMarginFraction,
        market,
        wallet,
        balanceTracking
      );
    }
  }

  function _loadTotalAccountValueAfterLiquidationAcquisition(
    ValidateInsuranceFundCannotLiquidateWalletArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking
  ) private view returns (int64 totalAccountValue) {
    int64 insuranceFundPositionSize;
    int64 liquidatingWalletPositionSize;
    for (uint8 i = 0; i < arguments.markets.length; i++) {
      liquidatingWalletPositionSize = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
        arguments.liquidatingWallet,
        arguments.markets[i].baseAssetSymbol
      );

      // Subtract quote quantity to acquire position at liquidation price
      if (liquidatingWalletPositionSize != 0) {
        totalAccountValue -= arguments.liquidationQuoteQuantities[i];
      }

      // Calculate Insurance Fund position size after acquiring position
      insuranceFundPositionSize =
        balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
          arguments.insuranceFundWallet,
          arguments.markets[i].baseAssetSymbol
        ) +
        liquidatingWalletPositionSize;

      // If position is non-zero then include in total account value
      if (insuranceFundPositionSize != 0) {
        // Accumulate account value by first adding position value...
        totalAccountValue += Math.multiplyPipsByFraction(
          insuranceFundPositionSize,
          int64(arguments.indexPrices[i]),
          int64(Constants.PIP_PRICE_MULTIPLIER)
        );
      }
    }
  }

  function _loadTotalInitialMarginRequirementAfterLiquidationAcquisition(
    ValidateInsuranceFundCannotLiquidateWalletArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private view returns (uint64 totalInitialMarginRequirement) {
    for (uint8 i = 0; i < arguments.markets.length; i++) {
      // Calculate Insurance Fund position size after acquiring position
      int64 insuranceFundPositionSize = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
        arguments.insuranceFundWallet,
        arguments.markets[i].baseAssetSymbol
      ) +
        balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
          arguments.liquidatingWallet,
          arguments.markets[i].baseAssetSymbol
        );

      // If position is non-zero then include margin requirement
      if (insuranceFundPositionSize != 0) {
        // Accumulate margin requirement
        totalInitialMarginRequirement += Math.abs(
          Math.multiplyPipsByFraction(
            Math.multiplyPipsByFraction(
              insuranceFundPositionSize,
              int64(arguments.indexPrices[i]),
              int64(Constants.PIP_PRICE_MULTIPLIER)
            ),
            int64(
              arguments.markets[i].loadInitialMarginFractionForWallet(
                insuranceFundPositionSize,
                arguments.insuranceFundWallet,
                marketOverridesByBaseAssetSymbolAndWallet
              )
            ),
            int64(Constants.PIP_PRICE_MULTIPLIER)
          )
        );
      }
    }
  }

  function loadTotalExitMaintenanceMarginRequirement(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (uint64 maintenanceMarginRequirement) {
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      Market storage market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      uint64 indexPrice = market.loadFeedPrice();

      maintenanceMarginRequirement += Math.abs(
        Math.multiplyPipsByFraction(
          Math.multiplyPipsByFraction(
            balanceTracking.loadBalanceFromMigrationSourceIfNeeded(arguments.wallet, baseAssetSymbols[i]),
            int64(indexPrice),
            int64(Constants.PIP_PRICE_MULTIPLIER)
          ),
          int64(
            market
              .loadMarketWithOverridesForWallet(arguments.wallet, marketOverridesByBaseAssetSymbolAndWallet)
              .maintenanceMarginFraction
          ),
          int64(Constants.PIP_PRICE_MULTIPLIER)
        )
      );
    }
  }

  function loadTotalWalletExitAccountValue(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64) {
    int64 totalAccountValue = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
      arguments.wallet,
      Constants.QUOTE_ASSET_SYMBOL
    );

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      Market memory market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      uint64 indexPrice = market.loadFeedPrice();

      Balance memory balance = balanceTracking.loadBalanceStructFromMigrationSourceIfNeeded(
        arguments.wallet,
        market.baseAssetSymbol
      );

      totalAccountValue += LiquidationValidations.calculateExitQuoteQuantity(
        balance.costBasis,
        indexPrice,
        balance.balance
      );
    }

    return totalAccountValue;
  }

  function validateInsuranceFundCannotLiquidateWallet(
    ValidateInsuranceFundCannotLiquidateWalletArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal view {
    int64 totalAccountValue = _loadTotalAccountValueAfterLiquidationAcquisition(arguments, balanceTracking);

    uint64 totalInitialMarginRequirement = _loadTotalInitialMarginRequirementAfterLiquidationAcquisition(
      arguments,
      balanceTracking,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    require(
      _isInsuranceFundMaximumPositionSizeExceededByLiquidationAcquisition(
        arguments,
        balanceTracking,
        marketOverridesByBaseAssetSymbolAndWallet
      ) || totalAccountValue < int64(totalInitialMarginRequirement),
      "Insurance fund can acquire"
    );
  }

  function _isInsuranceFundMaximumPositionSizeExceededByLiquidationAcquisition(
    ValidateInsuranceFundCannotLiquidateWalletArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private view returns (bool isMaximumPositionSizeExceeded) {
    int64 insuranceFundPositionSize;
    int64 liquidatingWalletPositionSize;
    for (uint8 i = 0; i < arguments.markets.length; i++) {
      liquidatingWalletPositionSize = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
        arguments.liquidatingWallet,
        arguments.markets[i].baseAssetSymbol
      );

      // Calculate Insurance Fund position size after acquiring position
      insuranceFundPositionSize =
        balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
          arguments.insuranceFundWallet,
          arguments.markets[i].baseAssetSymbol
        ) +
        liquidatingWalletPositionSize;

      if (
        Math.abs(insuranceFundPositionSize) >
        arguments
          .markets[i]
          .loadMarketWithOverridesForWallet(arguments.insuranceFundWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .maximumPositionSize
      ) {
        return true;
      }
    }

    return false;
  }

  function _loadMarginRequirement(
    IndexPrice memory indexPrice,
    address[] memory indexPriceCollectionServiceWallets,
    uint64 marginFraction,
    Market memory market,
    address wallet,
    BalanceTracking.Storage storage balanceTracking
  ) private view returns (uint64) {
    Validations.validateIndexPrice(indexPrice, indexPriceCollectionServiceWallets, market);

    return
      Math.abs(
        Math.multiplyPipsByFraction(
          Math.multiplyPipsByFraction(
            balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol),
            int64(indexPrice.price),
            int64(Constants.PIP_PRICE_MULTIPLIER)
          ),
          int64(marginFraction),
          int64(Constants.PIP_PRICE_MULTIPLIER)
        )
      );
  }
}
