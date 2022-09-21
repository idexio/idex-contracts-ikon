// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { DeleverageType } from './Enums.sol';
import { LiquidationValidations } from './LiquidationValidations.sol';
import { Margin } from './Margin.sol';
import { Math } from './Math.sol';
import { MarketOverrides } from './MarketOverrides.sol';
import { String } from './String.sol';
import { SortedStringSet } from './SortedStringSet.sol';
import { Validations } from './Validations.sol';
import { Balance, Market, OraclePrice } from './Structs.sol';

library Deleveraging {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketOverrides for Market;
  using SortedStringSet for string[];

  struct DeleverageLiquidationAcquisitionArguments {
    // External arguments
    DeleverageType deleverageType;
    string baseAssetSymbol;
    address deleveragingWallet;
    address liquidatingWallet;
    int64[] liquidationQuoteQuantitiesInPips; // For all open positions
    int64 liquidationBaseQuantityInPips; // For the position being liquidated
    int64 liquidationQuoteQuantityInPips; // For the position being liquidated
    OraclePrice[] deleveragingWalletOraclePrices; // After acquiring liquidating positions
    OraclePrice[] insuranceFundOraclePrices; // After acquiring liquidating positions
    OraclePrice[] liquidatingWalletOraclePrices; // Before liquidation
    // Exchange state
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
    address insuranceFundWallet;
    address oracleWallet;
  }

  struct DeleverageLiquidationClosureArguments {
    // External arguments
    DeleverageType deleverageType;
    string baseAssetSymbol;
    address deleveragingWallet;
    address liquidatingWallet;
    int64 liquidationBaseQuantityInPips;
    int64 liquidationQuoteQuantityInPips;
    OraclePrice[] liquidatingWalletOraclePrices; // Before liquidation
    OraclePrice[] deleveragingWalletOraclePrices; // After acquiring IF positions
    // Exchange state
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
    address oracleWallet;
  }

  function deleverageLiquidationAcquisition(
    DeleverageLiquidationAcquisitionArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal {
    // Validate that the liquidating account has fallen below margin requirements
    (
      int64 totalAccountValueInPips,
      uint64 totalMaintenanceMarginRequirementInPips
    ) = Margin.loadTotalAccountValueAndMaintenanceMarginRequirement(
        Margin.LoadArguments(
          arguments.liquidatingWallet,
          arguments.liquidatingWalletOraclePrices,
          arguments.oracleWallet,
          arguments.quoteAssetDecimals,
          arguments.quoteAssetSymbol
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    if (arguments.deleverageType == DeleverageType.InMaintenanceAcquisition) {
      require(
        totalAccountValueInPips <
          int64(totalMaintenanceMarginRequirementInPips),
        'Maintenance margin requirement met'
      );
    }

    // Do not proceed with deleverage if the Insurance Fund can acquire the wallet's positions
    validateInsuranceFundCannotLiquidateWallet(
      arguments,
      totalAccountValueInPips,
      totalMaintenanceMarginRequirementInPips,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    // Liquidate specified position by deleveraging a counterparty position at the liquidating wallet's bankruptcy price
    validateQuoteQuantityAndDeleveragePosition(
      arguments,
      totalAccountValueInPips,
      totalMaintenanceMarginRequirementInPips,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function deleverageLiquidationClosure(
    DeleverageLiquidationClosureArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal {
    (
      Market memory market,
      OraclePrice memory oraclePrice
    ) = loadMarketAndOraclePrice(
        arguments,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      );

    validateQuoteQuantityAndDeleveragePosition(
      arguments,
      market,
      oraclePrice,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function validateQuoteQuantityAndDeleveragePosition(
    DeleverageLiquidationAcquisitionArguments memory arguments,
    int64 totalAccountValueInPips,
    uint64 totalMaintenanceMarginRequirementInPips,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    (
      Market memory market,
      OraclePrice memory oraclePrice
    ) = loadMarketAndOraclePrice(
        arguments,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      );
    uint64 oraclePriceInPips = Validations.validateOraclePriceAndConvertToPips(
      oraclePrice,
      arguments.quoteAssetDecimals,
      market,
      arguments.oracleWallet
    );

    Balance storage balance = balanceTracking.loadBalanceAndMigrateIfNeeded(
      arguments.liquidatingWallet,
      market.baseAssetSymbol
    );

    if (arguments.deleverageType == DeleverageType.InMaintenanceAcquisition) {
      LiquidationValidations.validateLiquidationQuoteQuantity(
        arguments.liquidationQuoteQuantityInPips,
        market
          .loadMarketWithOverridesForWallet(
            arguments.liquidatingWallet,
            marketOverridesByBaseAssetSymbolAndWallet
          )
          .maintenanceMarginFractionInPips,
        oraclePriceInPips,
        balance.balanceInPips,
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips
      );
    } else {
      // DeleverageType.ExitAcquisition
      LiquidationValidations.validateExitQuoteQuantity(
        Math.multiplyPipsByFraction(
          balance.costBasisInPips,
          arguments.liquidationBaseQuantityInPips,
          balance.balanceInPips
        ),
        arguments.liquidationQuoteQuantityInPips,
        market
          .loadMarketWithOverridesForWallet(
            arguments.liquidatingWallet,
            marketOverridesByBaseAssetSymbolAndWallet
          )
          .maintenanceMarginFractionInPips,
        oraclePriceInPips,
        balance.balanceInPips,
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips
      );
    }

    balanceTracking.updatePositionForDeleverage(
      arguments.liquidationBaseQuantityInPips,
      arguments.deleveragingWallet,
      arguments.liquidatingWallet,
      market,
      arguments.quoteAssetSymbol,
      arguments.liquidationQuoteQuantityInPips,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    // Validate that the deleveraged wallet still meets its initial margin requirements
    Margin.loadAndValidateTotalAccountValueAndInitialMarginRequirement(
      Margin.LoadArguments(
        arguments.deleveragingWallet,
        arguments.deleveragingWalletOraclePrices,
        arguments.oracleWallet,
        arguments.quoteAssetDecimals,
        arguments.quoteAssetSymbol
      ),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function validateQuoteQuantityAndDeleveragePosition(
    DeleverageLiquidationClosureArguments memory arguments,
    Market memory market,
    OraclePrice memory oraclePrice,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    Balance storage balance = balanceTracking.loadBalanceAndMigrateIfNeeded(
      arguments.liquidatingWallet,
      market.baseAssetSymbol
    );
    uint64 oraclePriceInPips = Validations.validateOraclePriceAndConvertToPips(
      oraclePrice,
      arguments.quoteAssetDecimals,
      market,
      arguments.oracleWallet
    );

    if (arguments.deleverageType == DeleverageType.InsuranceFundClosure) {
      LiquidationValidations.validateInsuranceFundClosureQuoteQuantityInPips(
        arguments.liquidationBaseQuantityInPips,
        balance.costBasisInPips,
        balance.balanceInPips,
        arguments.liquidationQuoteQuantityInPips
      );
    } else {
      // DeleverageType.ExitFundClosure
      (
        int64 totalAccountValueInPips,
        uint64 totalMaintenanceMarginRequirementInPips
      ) = Margin.loadTotalAccountValueAndMaintenanceMarginRequirement(
          Margin.LoadArguments(
            arguments.liquidatingWallet,
            arguments.liquidatingWalletOraclePrices,
            arguments.oracleWallet,
            arguments.quoteAssetDecimals,
            arguments.quoteAssetSymbol
          ),
          balanceTracking,
          baseAssetSymbolsWithOpenPositionsByWallet,
          marketOverridesByBaseAssetSymbolAndWallet,
          marketsByBaseAssetSymbol
        );

      LiquidationValidations.validateExitFundClosureQuoteQuantityInPips(
        arguments.liquidationBaseQuantityInPips,
        market
          .loadMarketWithOverridesForWallet(
            arguments.liquidatingWallet,
            marketOverridesByBaseAssetSymbolAndWallet
          )
          .maintenanceMarginFractionInPips,
        oraclePriceInPips,
        balance.balanceInPips,
        arguments.liquidationQuoteQuantityInPips,
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips
      );
    }

    balanceTracking.updatePositionForDeleverage(
      arguments.liquidationBaseQuantityInPips,
      arguments.deleveragingWallet,
      arguments.liquidatingWallet,
      market,
      arguments.quoteAssetSymbol,
      arguments.liquidationQuoteQuantityInPips,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    // Validate that the deleveraged wallet still meets its initial margin requirements
    // TODO Should this be maintenance margin?
    Margin.loadAndValidateTotalAccountValueAndInitialMarginRequirement(
      Margin.LoadArguments(
        arguments.deleveragingWallet,
        arguments.deleveragingWalletOraclePrices,
        arguments.oracleWallet,
        arguments.quoteAssetDecimals,
        arguments.quoteAssetSymbol
      ),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function loadMarketAndOraclePrice(
    DeleverageLiquidationAcquisitionArguments memory arguments,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  )
    private
    view
    returns (Market memory market, OraclePrice memory oraclePrice)
  {
    string[]
      memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
        arguments.liquidatingWallet
      ];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      if (String.isEqual(baseAssetSymbols[i], arguments.baseAssetSymbol)) {
        market = marketsByBaseAssetSymbol[arguments.baseAssetSymbol];
        oraclePrice = arguments.liquidatingWalletOraclePrices[i];
      }
    }

    require(market.exists, 'Invalid market');
  }

  function loadMarketAndOraclePrice(
    DeleverageLiquidationClosureArguments memory arguments,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  )
    private
    view
    returns (Market memory market, OraclePrice memory oraclePrice)
  {
    string[]
      memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
        arguments.liquidatingWallet
      ];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      if (String.isEqual(baseAssetSymbols[i], arguments.baseAssetSymbol)) {
        market = marketsByBaseAssetSymbol[arguments.baseAssetSymbol];
        oraclePrice = arguments.liquidatingWalletOraclePrices[i];
      }
    }

    require(market.exists, 'Invalid market');
  }

  function validateInsuranceFundCannotLiquidateWallet(
    DeleverageLiquidationAcquisitionArguments memory arguments,
    int64 liquidatingWalletTotalAccountValueInPips,
    uint64 liquidatingWalletTotalMaintenanceMarginRequirementInPips,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    string[]
      memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
        arguments.insuranceFundWallet
      ].merge(
          baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet]
        );

    Margin.ValidateInsuranceFundCannotLiquidateWalletArguments
      memory loadArguments = Margin
        .ValidateInsuranceFundCannotLiquidateWalletArguments(
          arguments.insuranceFundWallet,
          arguments.liquidatingWallet,
          arguments.liquidationQuoteQuantitiesInPips,
          new Market[](baseAssetSymbols.length),
          new uint64[](baseAssetSymbols.length),
          arguments.oracleWallet,
          arguments.quoteAssetDecimals,
          arguments.quoteAssetSymbol
        );

    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      // Load market and oracle price for symbol
      loadArguments.markets[i] = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      loadArguments.oraclePricesInPips[i] = Validations
        .validateAndUpdateOraclePriceAndConvertToPips(
          arguments.insuranceFundOraclePrices[i],
          arguments.quoteAssetDecimals,
          marketsByBaseAssetSymbol[baseAssetSymbols[i]],
          arguments.oracleWallet
        );

      // Validate provided liquidation quote quantity
      if (arguments.deleverageType == DeleverageType.InMaintenanceAcquisition) {
        LiquidationValidations.validateLiquidationQuoteQuantity(
          arguments.liquidationQuoteQuantitiesInPips[i],
          loadArguments
            .markets[i]
            .loadMarketWithOverridesForWallet(
              arguments.liquidatingWallet,
              marketOverridesByBaseAssetSymbolAndWallet
            )
            .maintenanceMarginFractionInPips,
          loadArguments.oraclePricesInPips[i],
          balanceTracking
            .loadBalanceAndMigrateIfNeeded(
              arguments.liquidatingWallet,
              baseAssetSymbols[i]
            )
            .balanceInPips,
          liquidatingWalletTotalAccountValueInPips,
          liquidatingWalletTotalMaintenanceMarginRequirementInPips
        );
      } else {
        // DeleverageType.ExitAcquisition
        Balance storage balance = balanceTracking.loadBalanceAndMigrateIfNeeded(
          arguments.liquidatingWallet,
          loadArguments.markets[i].baseAssetSymbol
        );
        LiquidationValidations.validateExitQuoteQuantity(
          Math.multiplyPipsByFraction(
            balance.costBasisInPips,
            arguments.liquidationBaseQuantityInPips,
            balance.balanceInPips
          ),
          arguments.liquidationQuoteQuantitiesInPips[i],
          loadArguments
            .markets[i]
            .loadMarketWithOverridesForWallet(
              arguments.liquidatingWallet,
              marketOverridesByBaseAssetSymbolAndWallet
            )
            .maintenanceMarginFractionInPips,
          loadArguments.oraclePricesInPips[i],
          balanceTracking
            .loadBalanceAndMigrateIfNeeded(
              arguments.liquidatingWallet,
              baseAssetSymbols[i]
            )
            .balanceInPips,
          liquidatingWalletTotalAccountValueInPips,
          liquidatingWalletTotalMaintenanceMarginRequirementInPips
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
