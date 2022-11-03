// SPDX-License-Identifier: LGPL-3.0-only

import { AssetUnitConversions } from './AssetUnitConversions.sol';
import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { LiquidationType } from './Enums.sol';
import { LiquidationValidations } from './LiquidationValidations.sol';
import { MarketHelper } from './MarketHelper.sol';
import { MarketOverrides } from './MarketOverrides.sol';
import { Math } from './Math.sol';
import { String } from './String.sol';
import { Validations } from './Validations.sol';
import { Balance, Market, OraclePrice } from './Structs.sol';

pragma solidity 0.8.17;

library Margin {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
  using MarketOverrides for Market;

  struct LoadArguments {
    address wallet;
    OraclePrice[] oraclePrices;
    address oracleWallet;
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
  }

  struct ValidateInsuranceFundCannotLiquidateWalletArguments {
    address insuranceFundWallet;
    address liquidatingWallet;
    int64[] liquidationQuoteQuantitiesInPips;
    Market[] markets;
    uint64[] oraclePricesInPips;
    address oracleWallet;
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
  }

  function loadTotalInitialMarginRequirement(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 quoteAssetDecimals,
    address oracleWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (uint64 initialMarginRequirement) {
    string[] memory marketSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
      wallet
    ];
    for (uint8 i = 0; i < marketSymbols.length; i++) {
      (Market memory market, OraclePrice memory oraclePrice) = (
        marketsByBaseAssetSymbol[marketSymbols[i]],
        oraclePrices[i]
      );

      initialMarginRequirement += loadMarginRequirement(
        wallet,
        market.baseAssetSymbol,
        market.loadInitialMarginFractionInPipsForWallet(
          balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
            wallet,
            market.baseAssetSymbol
          ),
          wallet,
          marketOverridesByBaseAssetSymbolAndWallet
        ),
        oraclePrice,
        quoteAssetDecimals,
        oracleWallet,
        balanceTracking
      );
    }
  }

  function loadTotalMaintenanceMarginRequirement(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 quoteAssetDecimals,
    address oracleWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (uint64 maintenanceMarginRequirement) {
    string[]
      memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
        wallet
      ];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      (Market memory market, OraclePrice memory oraclePrice) = (
        marketsByBaseAssetSymbol[baseAssetSymbols[i]],
        oraclePrices[i]
      );

      maintenanceMarginRequirement += loadMarginRequirement(
        wallet,
        market.baseAssetSymbol,
        market
          .loadMarketWithOverridesForWallet(
            wallet,
            marketOverridesByBaseAssetSymbolAndWallet
          )
          .maintenanceMarginFractionInPips,
        oraclePrice,
        quoteAssetDecimals,
        oracleWallet,
        balanceTracking
      );
    }
  }

  /**
   * @dev TODO Utterly crass naming
   */
  function isInitialMarginRequirementMetAndUpdateLastOraclePrice(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
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
        loadTotalInitialMarginRequirementAndUpdateLastOraclePrice(
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
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  )
    internal
    returns (
      int64 totalAccountValueInPips,
      uint64 totalInitialMarginRequirementInPips
    )
  {
    totalAccountValueInPips = Margin.loadTotalAccountValue(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    totalInitialMarginRequirementInPips = loadTotalInitialMarginRequirementAndUpdateLastOraclePrice(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    require(
      totalAccountValueInPips >= int64(totalInitialMarginRequirementInPips),
      'Initial margin requirement not met'
    );

    return (totalAccountValueInPips, totalInitialMarginRequirementInPips);
  }

  function loadTotalAccountValue(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64) {
    int64 totalAccountValueInPips = balanceTracking
      .loadBalanceInPipsFromMigrationSourceIfNeeded(
        arguments.wallet,
        arguments.quoteAssetSymbol
      );

    string[]
      memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
        arguments.wallet
      ];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      Market memory market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      uint64 oraclePriceInPips = Validations
        .validateOraclePriceAndConvertToPips(
          arguments.oraclePrices[i],
          arguments.quoteAssetDecimals,
          market,
          arguments.oracleWallet
        );

      totalAccountValueInPips += Math.multiplyPipsByFraction(
        balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
          arguments.wallet,
          market.baseAssetSymbol
        ),
        int64(oraclePriceInPips),
        int64(Constants.pipPriceMultiplier)
      );
    }

    return totalAccountValueInPips;
  }

  function loadTotalAccountValueAfterLiquidationAcquisition(
    Margin.ValidateInsuranceFundCannotLiquidateWalletArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking
  ) private view returns (int64 totalAccountValueInPips) {
    int64 insuranceFundPositionSizeInPips;
    int64 liquidatingWalletPositionSizeInPips;
    for (uint8 i = 0; i < arguments.markets.length; i++) {
      liquidatingWalletPositionSizeInPips = balanceTracking
        .loadBalanceInPipsFromMigrationSourceIfNeeded(
          arguments.liquidatingWallet,
          arguments.markets[i].baseAssetSymbol
        );

      // Subtract quote quantity to acquire position at liquidation price
      if (liquidatingWalletPositionSizeInPips != 0) {
        totalAccountValueInPips -= arguments.liquidationQuoteQuantitiesInPips[
          i
        ];
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
          int64(arguments.oraclePricesInPips[i]),
          int64(Constants.pipPriceMultiplier)
        );
      }
    }
  }

  function loadTotalInitialMarginRequirementAfterLiquidationAcquisition(
    Margin.ValidateInsuranceFundCannotLiquidateWalletArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) private view returns (uint64 totalInitialMarginRequirementInPips) {
    for (uint8 i = 0; i < arguments.markets.length; i++) {
      // Calculate Insurance Fund position size after acquiring position
      int64 insuranceFundPositionSizeInPips = balanceTracking
        .loadBalanceInPipsFromMigrationSourceIfNeeded(
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
              int64(arguments.oraclePricesInPips[i]),
              int64(Constants.pipPriceMultiplier)
            ),
            int64(
              arguments.markets[i].loadInitialMarginFractionInPipsForWallet(
                insuranceFundPositionSizeInPips,
                arguments.insuranceFundWallet,
                marketOverridesByBaseAssetSymbolAndWallet
              )
            ),
            int64(Constants.pipPriceMultiplier)
          )
        );
      }
    }
  }

  function loadTotalAccountValueAndMaintenanceMarginRequirement(
    Margin.LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  )
    internal
    returns (
      int64 totalAccountValueInPips,
      uint64 totalMaintenanceMarginRequirementInPips
    )
  {
    totalAccountValueInPips = Margin.loadTotalAccountValue(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    totalMaintenanceMarginRequirementInPips = Margin
      .loadTotalMaintenanceMarginRequirementAndUpdateLastOraclePrice(
        arguments,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
  }

  function loadTotalInitialMarginRequirementAndUpdateLastOraclePrice(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal returns (uint64 initialMarginRequirement) {
    string[] memory marketSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
      arguments.wallet
    ];
    for (uint8 i = 0; i < marketSymbols.length; i++) {
      (Market storage market, OraclePrice memory oraclePrice) = (
        marketsByBaseAssetSymbol[marketSymbols[i]],
        arguments.oraclePrices[i]
      );

      initialMarginRequirement += loadMarginRequirementAndUpdateLastOraclePrice(
        arguments,
        market,
        market.loadInitialMarginFractionInPipsForWallet(
          balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
            arguments.wallet,
            market.baseAssetSymbol
          ),
          arguments.wallet,
          marketOverridesByBaseAssetSymbolAndWallet
        ),
        oraclePrice,
        balanceTracking
      );
    }
  }

  function loadTotalExitMaintenanceMarginRequirement(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (uint64 maintenanceMarginRequirement) {
    string[]
      memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
        arguments.wallet
      ];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      Market storage market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      uint64 oraclePriceInPips = market.loadFeedPriceInPips();

      maintenanceMarginRequirement += Math.abs(
        Math.multiplyPipsByFraction(
          Math.multiplyPipsByFraction(
            balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
              arguments.wallet,
              baseAssetSymbols[i]
            ),
            int64(oraclePriceInPips),
            int64(Constants.pipPriceMultiplier)
          ),
          int64(
            market
              .loadMarketWithOverridesForWallet(
                arguments.wallet,
                marketOverridesByBaseAssetSymbolAndWallet
              )
              .maintenanceMarginFractionInPips
          ),
          int64(Constants.pipPriceMultiplier)
        )
      );
    }
  }

  function loadTotalMaintenanceMarginRequirementAndUpdateLastOraclePrice(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal returns (uint64 maintenanceMarginRequirement) {
    string[] memory marketSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
      arguments.wallet
    ];
    for (uint8 i = 0; i < marketSymbols.length; i++) {
      (Market storage market, OraclePrice memory oraclePrice) = (
        marketsByBaseAssetSymbol[marketSymbols[i]],
        arguments.oraclePrices[i]
      );

      maintenanceMarginRequirement += loadMarginRequirementAndUpdateLastOraclePrice(
        arguments,
        market,
        market
          .loadMarketWithOverridesForWallet(
            arguments.wallet,
            marketOverridesByBaseAssetSymbolAndWallet
          )
          .maintenanceMarginFractionInPips,
        oraclePrice,
        balanceTracking
      );
    }
  }

  function loadTotalWalletExitAccountValue(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64) {
    int64 totalAccountValueInPips = balanceTracking
      .loadBalanceInPipsFromMigrationSourceIfNeeded(
        arguments.wallet,
        arguments.quoteAssetSymbol
      );

    string[] memory marketSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
      arguments.wallet
    ];
    for (uint8 i = 0; i < marketSymbols.length; i++) {
      Market memory market = marketsByBaseAssetSymbol[marketSymbols[i]];
      uint64 oraclePriceInPips = market.loadFeedPriceInPips();

      Balance memory balance = balanceTracking
        .loadBalanceFromMigrationSourceIfNeeded(
          arguments.wallet,
          market.baseAssetSymbol
        );

      totalAccountValueInPips += Math.min(
        balance.costBasisInPips,
        Math.multiplyPipsByFraction(
          balance.balanceInPips,
          int64(oraclePriceInPips),
          int64(Constants.pipPriceMultiplier)
        )
      );
    }

    return totalAccountValueInPips;
  }

  function validateInsuranceFundCannotLiquidateWallet(
    Margin.ValidateInsuranceFundCannotLiquidateWalletArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal view {
    int64 totalAccountValueInPips = loadTotalAccountValueAfterLiquidationAcquisition(
        arguments,
        balanceTracking
      );

    uint64 totalInitialMarginRequirementInPips = loadTotalInitialMarginRequirementAfterLiquidationAcquisition(
        arguments,
        balanceTracking,
        marketOverridesByBaseAssetSymbolAndWallet
      );

    require(
      totalAccountValueInPips < int64(totalInitialMarginRequirementInPips),
      'Insurance fund can acquire'
    );
  }

  function loadMarginRequirement(
    address wallet,
    string memory baseAssetSymbol,
    uint64 marginFractionInPips,
    OraclePrice memory oraclePrice,
    uint8 quoteAssetDecimals,
    address oracleWallet,
    BalanceTracking.Storage storage balanceTracking
  ) private view returns (uint64) {
    require(
      String.isEqual(baseAssetSymbol, oraclePrice.baseAssetSymbol),
      'Oracle price mismatch'
    );
    Validations.validateOraclePriceSignature(oraclePrice, oracleWallet);

    return
      Math.abs(
        Math.multiplyPipsByFraction(
          Math.multiplyPipsByFraction(
            balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
              wallet,
              baseAssetSymbol
            ),
            int64(
              AssetUnitConversions.assetUnitsToPips(
                oraclePrice.priceInAssetUnits,
                quoteAssetDecimals
              )
            ),
            int64(Constants.pipPriceMultiplier)
          ),
          int64(marginFractionInPips),
          int64(Constants.pipPriceMultiplier)
        )
      );
  }

  /**
   * @dev This function is painfully similar to loadMarginRequirement but is separately declared to satisfy state
   * mutability and avoid redundant looping
   */
  function loadMarginRequirementAndUpdateLastOraclePrice(
    LoadArguments memory arguments,
    Market storage market,
    uint64 marginFractionInPips,
    OraclePrice memory oraclePrice,
    BalanceTracking.Storage storage balanceTracking
  ) private returns (uint64) {
    require(
      String.isEqual(market.baseAssetSymbol, oraclePrice.baseAssetSymbol),
      'Oracle price mismatch'
    );
    uint64 oraclePriceInPips = Validations
      .validateAndUpdateOraclePriceAndConvertToPips(
        market,
        oraclePrice,
        arguments.oracleWallet,
        arguments.quoteAssetDecimals
      );

    return
      Math.abs(
        Math.multiplyPipsByFraction(
          Math.multiplyPipsByFraction(
            balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
              arguments.wallet,
              market.baseAssetSymbol
            ),
            int64(oraclePriceInPips),
            int64(Constants.pipPriceMultiplier)
          ),
          int64(marginFractionInPips),
          int64(Constants.pipPriceMultiplier)
        )
      );
  }
}
