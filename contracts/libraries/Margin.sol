// SPDX-License-Identifier: LGPL-3.0-only

import { AssetUnitConversions } from "./AssetUnitConversions.sol";
import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { LiquidationType } from "./Enums.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { MarketOverrides } from "./MarketOverrides.sol";
import { Math } from "./Math.sol";
import { String } from "./String.sol";
import { Validations } from "./Validations.sol";
import { Balance, Market, IndexPrice } from "./Structs.sol";

pragma solidity 0.8.17;

library Margin {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
  using MarketOverrides for Market;

  struct LoadArguments {
    address wallet;
    IndexPrice[] indexPrices;
    address indexWallet;
  }

  struct ValidateInsuranceFundCannotLiquidateWalletArguments {
    address insuranceFundWallet;
    address liquidatingWallet;
    int64[] liquidationQuoteQuantitiesInPips;
    Market[] markets;
    uint64[] indexPricesInPips;
    address indexWallet;
  }

  function loadTotalInitialMarginRequirement(
    address wallet,
    IndexPrice[] memory indexPrices,
    address indexWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (uint64 initialMarginRequirement) {
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      (Market memory market, IndexPrice memory indexPrice) = (
        marketsByBaseAssetSymbol[baseAssetSymbols[i]],
        indexPrices[i]
      );

      initialMarginRequirement += _loadMarginRequirement(
        wallet,
        market.baseAssetSymbol,
        market.loadInitialMarginFractionInPipsForWallet(
          balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol),
          wallet,
          marketOverridesByBaseAssetSymbolAndWallet
        ),
        indexPrice,
        indexWallet,
        balanceTracking
      );
    }
  }

  function loadTotalMaintenanceMarginRequirement(
    address wallet,
    IndexPrice[] memory indexPrices,
    address indexWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (uint64 maintenanceMarginRequirement) {
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      (Market memory market, IndexPrice memory indexPrice) = (
        marketsByBaseAssetSymbol[baseAssetSymbols[i]],
        indexPrices[i]
      );

      maintenanceMarginRequirement += _loadMarginRequirement(
        wallet,
        market.baseAssetSymbol,
        market
          .loadMarketWithOverridesForWallet(wallet, marketOverridesByBaseAssetSymbolAndWallet)
          .maintenanceMarginFractionInPips,
        indexPrice,
        indexWallet,
        balanceTracking
      );
    }
  }

  /**
   * @dev TODO Utterly crass naming
   */
  function isInitialMarginRequirementMetAndUpdateLastIndexPrice(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal returns (bool) {
    return
      loadTotalAccountValue(
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

  function loadAndValidateTotalAccountValueAndInitialMarginRequirement(
    Margin.LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal returns (int64 totalAccountValueInPips, uint64 totalInitialMarginRequirementInPips) {
    totalAccountValueInPips = Margin.loadTotalAccountValue(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    totalInitialMarginRequirementInPips = loadTotalInitialMarginRequirementAndUpdateLastIndexPrice(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    require(
      totalAccountValueInPips >= int64(totalInitialMarginRequirementInPips),
      "Initial margin requirement not met"
    );

    return (totalAccountValueInPips, totalInitialMarginRequirementInPips);
  }

  function loadTotalAccountValue(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64) {
    int64 totalAccountValueInPips = balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
      arguments.wallet,
      Constants.QUOTE_ASSET_SYMBOL
    );

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      Market memory market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      uint64 indexPriceInPips = Validations.validateIndexPriceAndConvertToPips(
        arguments.indexPrices[i],
        market,
        arguments.indexWallet
      );

      totalAccountValueInPips += Math.multiplyPipsByFraction(
        balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(arguments.wallet, market.baseAssetSymbol),
        int64(indexPriceInPips),
        int64(Constants.PIP_PRICE_MULTIPLIER)
      );
    }

    return totalAccountValueInPips;
  }

  function _loadTotalAccountValueAfterLiquidationAcquisition(
    Margin.ValidateInsuranceFundCannotLiquidateWalletArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking
  ) private view returns (int64 totalAccountValueInPips) {
    int64 insuranceFundPositionSizeInPips;
    int64 liquidatingWalletPositionSizeInPips;
    for (uint8 i = 0; i < arguments.markets.length; i++) {
      liquidatingWalletPositionSizeInPips = balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
        arguments.liquidatingWallet,
        arguments.markets[i].baseAssetSymbol
      );

      // Subtract quote quantity to acquire position at liquidation price
      if (liquidatingWalletPositionSizeInPips != 0) {
        totalAccountValueInPips -= arguments.liquidationQuoteQuantitiesInPips[i];
      }

      // Calculate Insurance Fund position size after acquiring position
      insuranceFundPositionSizeInPips =
        balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
          arguments.insuranceFundWallet,
          arguments.markets[i].baseAssetSymbol
        ) +
        liquidatingWalletPositionSizeInPips;

      // If position is non-zero then include in total account value
      if (insuranceFundPositionSizeInPips != 0) {
        // Accumulate account value by first adding position value...
        totalAccountValueInPips += Math.multiplyPipsByFraction(
          insuranceFundPositionSizeInPips,
          int64(arguments.indexPricesInPips[i]),
          int64(Constants.PIP_PRICE_MULTIPLIER)
        );
      }
    }
  }

  function _loadTotalInitialMarginRequirementAfterLiquidationAcquisition(
    Margin.ValidateInsuranceFundCannotLiquidateWalletArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private view returns (uint64 totalInitialMarginRequirementInPips) {
    for (uint8 i = 0; i < arguments.markets.length; i++) {
      // Calculate Insurance Fund position size after acquiring position
      int64 insuranceFundPositionSizeInPips = balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
        arguments.insuranceFundWallet,
        arguments.markets[i].baseAssetSymbol
      ) +
        balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
          arguments.liquidatingWallet,
          arguments.markets[i].baseAssetSymbol
        );

      // If position is non-zero then include margin requirement
      if (insuranceFundPositionSizeInPips != 0) {
        // Accumulate margin requirement
        totalInitialMarginRequirementInPips += Math.abs(
          Math.multiplyPipsByFraction(
            Math.multiplyPipsByFraction(
              insuranceFundPositionSizeInPips,
              int64(arguments.indexPricesInPips[i]),
              int64(Constants.PIP_PRICE_MULTIPLIER)
            ),
            int64(
              arguments.markets[i].loadInitialMarginFractionInPipsForWallet(
                insuranceFundPositionSizeInPips,
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

  function loadTotalAccountValueAndMaintenanceMarginRequirement(
    Margin.LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal returns (int64 totalAccountValueInPips, uint64 totalMaintenanceMarginRequirementInPips) {
    totalAccountValueInPips = Margin.loadTotalAccountValue(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    totalMaintenanceMarginRequirementInPips = Margin.loadTotalMaintenanceMarginRequirementAndUpdateLastIndexPrice(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function loadTotalInitialMarginRequirementAndUpdateLastIndexPrice(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
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
        market,
        market.loadInitialMarginFractionInPipsForWallet(
          balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(arguments.wallet, market.baseAssetSymbol),
          arguments.wallet,
          marketOverridesByBaseAssetSymbolAndWallet
        ),
        indexPrice,
        balanceTracking
      );
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
      uint64 indexPriceInPips = market.loadFeedPriceInPips();

      maintenanceMarginRequirement += Math.abs(
        Math.multiplyPipsByFraction(
          Math.multiplyPipsByFraction(
            balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(arguments.wallet, baseAssetSymbols[i]),
            int64(indexPriceInPips),
            int64(Constants.PIP_PRICE_MULTIPLIER)
          ),
          int64(
            market
              .loadMarketWithOverridesForWallet(arguments.wallet, marketOverridesByBaseAssetSymbolAndWallet)
              .maintenanceMarginFractionInPips
          ),
          int64(Constants.PIP_PRICE_MULTIPLIER)
        )
      );
    }
  }

  function loadTotalMaintenanceMarginRequirementAndUpdateLastIndexPrice(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
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
        market,
        market
          .loadMarketWithOverridesForWallet(arguments.wallet, marketOverridesByBaseAssetSymbolAndWallet)
          .maintenanceMarginFractionInPips,
        indexPrice,
        balanceTracking
      );
    }
  }

  function loadTotalWalletExitAccountValue(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64) {
    int64 totalAccountValueInPips = balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
      arguments.wallet,
      Constants.QUOTE_ASSET_SYMBOL
    );

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      Market memory market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      uint64 indexPriceInPips = market.loadFeedPriceInPips();

      Balance memory balance = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
        arguments.wallet,
        market.baseAssetSymbol
      );

      totalAccountValueInPips += Math.min(
        balance.costBasisInPips,
        Math.multiplyPipsByFraction(
          balance.balanceInPips,
          int64(indexPriceInPips),
          int64(Constants.PIP_PRICE_MULTIPLIER)
        )
      );
    }

    return totalAccountValueInPips;
  }

  function validateInsuranceFundCannotLiquidateWallet(
    Margin.ValidateInsuranceFundCannotLiquidateWalletArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal view {
    int64 totalAccountValueInPips = _loadTotalAccountValueAfterLiquidationAcquisition(arguments, balanceTracking);

    uint64 totalInitialMarginRequirementInPips = _loadTotalInitialMarginRequirementAfterLiquidationAcquisition(
      arguments,
      balanceTracking,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    require(
      _isInsuranceFundMaximumPositionSizeExceededByLiquidationAcquisition(
        arguments,
        balanceTracking,
        marketOverridesByBaseAssetSymbolAndWallet
      ) || totalAccountValueInPips < int64(totalInitialMarginRequirementInPips),
      "Insurance fund can acquire"
    );
  }

  function _isInsuranceFundMaximumPositionSizeExceededByLiquidationAcquisition(
    Margin.ValidateInsuranceFundCannotLiquidateWalletArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private view returns (bool isMaximumPositionSizeExceeded) {
    int64 insuranceFundPositionSizeInPips;
    int64 liquidatingWalletPositionSizeInPips;
    for (uint8 i = 0; i < arguments.markets.length; i++) {
      liquidatingWalletPositionSizeInPips = balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
        arguments.liquidatingWallet,
        arguments.markets[i].baseAssetSymbol
      );

      // Calculate Insurance Fund position size after acquiring position
      insuranceFundPositionSizeInPips =
        balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
          arguments.insuranceFundWallet,
          arguments.markets[i].baseAssetSymbol
        ) +
        liquidatingWalletPositionSizeInPips;

      if (
        Math.abs(insuranceFundPositionSizeInPips) >
        arguments
          .markets[i]
          .loadMarketWithOverridesForWallet(arguments.insuranceFundWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .maximumPositionSizeInPips
      ) {
        return true;
      }
    }

    return false;
  }

  function _loadMarginRequirement(
    address wallet,
    string memory baseAssetSymbol,
    uint64 marginFractionInPips,
    IndexPrice memory indexPrice,
    address indexWallet,
    BalanceTracking.Storage storage balanceTracking
  ) private view returns (uint64) {
    require(String.isEqual(baseAssetSymbol, indexPrice.baseAssetSymbol), "Index price mismatch");
    Validations.validateIndexPriceSignature(indexPrice, indexWallet);

    return
      Math.abs(
        Math.multiplyPipsByFraction(
          Math.multiplyPipsByFraction(
            balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(wallet, baseAssetSymbol),
            int64(AssetUnitConversions.assetUnitsToPips(indexPrice.priceInAssetUnits, Constants.QUOTE_ASSET_DECIMALS)),
            int64(Constants.PIP_PRICE_MULTIPLIER)
          ),
          int64(marginFractionInPips),
          int64(Constants.PIP_PRICE_MULTIPLIER)
        )
      );
  }

  /**
   * @dev This function is painfully similar to _loadMarginRequirement but is separately declared to satisfy state
   * mutability and avoid redundant looping
   */
  function _loadMarginRequirementAndUpdateLastIndexPrice(
    LoadArguments memory arguments,
    Market storage market,
    uint64 marginFractionInPips,
    IndexPrice memory indexPrice,
    BalanceTracking.Storage storage balanceTracking
  ) private returns (uint64) {
    require(String.isEqual(market.baseAssetSymbol, indexPrice.baseAssetSymbol), "Index price mismatch");
    uint64 indexPriceInPips = Validations.validateAndUpdateIndexPriceAndConvertToPips(
      market,
      indexPrice,
      arguments.indexWallet
    );

    return
      Math.abs(
        Math.multiplyPipsByFraction(
          Math.multiplyPipsByFraction(
            balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(arguments.wallet, market.baseAssetSymbol),
            int64(indexPriceInPips),
            int64(Constants.PIP_PRICE_MULTIPLIER)
          ),
          int64(marginFractionInPips),
          int64(Constants.PIP_PRICE_MULTIPLIER)
        )
      );
  }
}
