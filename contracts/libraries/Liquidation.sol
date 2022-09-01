// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.15;

import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { LiquidationValidations } from './LiquidationValidations.sol';
import { Margin } from './Margin.sol';
import { MarketOverrides } from './MarketOverrides.sol';
import { String } from './String.sol';
import { SortedStringSet } from './SortedStringSet.sol';
import { Validations } from './Validations.sol';
import { Balance, Market, OraclePrice } from './Structs.sol';

library Liquidation {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketOverrides for Market;
  using SortedStringSet for string[];

  struct LiquidatePositionArguments {
    address counterpartyWallet;
    address liquidatingWallet;
    int64 liquidationBaseQuantityInPips;
    int64 liquidationQuoteQuantityInPips;
    Market market;
    OraclePrice oraclePrice;
    address oracleWallet;
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
    int64 totalAccountValueInPips;
    uint64 totalMaintenanceMarginRequirementInPips;
  }

  struct LiquidateWalletArguments {
    // External arguments
    address liquidatingWallet;
    int64[] liquidationQuoteQuantitiesInPips;
    OraclePrice[] insuranceFundOraclePrices;
    OraclePrice[] liquidatingWalletOraclePrices;
    // Exchange state
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
    address insuranceFundWallet;
    address oracleWallet;
  }

  struct LiquidationAcquisitionDeleverageArguments {
    // External arguments
    string baseAssetSymbol;
    address deleveragingWallet;
    address liquidatingWallet;
    int64[] liquidationQuoteQuantitiesInPips; // For all open positions
    int64 liquidationBaseQuantityInPips; // For the position being liquidating
    int64 liquidationQuoteQuantityInPips; // For the position being deleveraged
    OraclePrice[] deleveragingWalletOraclePrices; // After acquiring liquidating positions
    OraclePrice[] insuranceFundOraclePrices; // After acquiring liquidating positions
    OraclePrice[] liquidatingWalletOraclePrices; // Before liquidation
    // Exchange state
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
    address insuranceFundWallet;
    address oracleWallet;
  }

  struct LiquidationClosureDeleverageArguments {
    // External arguments
    string baseAssetSymbol;
    address deleveragingWallet;
    int64 liquidationBaseQuantityInPips;
    int64 liquidationQuoteQuantityInPips;
    OraclePrice[] deleveragingWalletOraclePrices; // After acquiring IF positions
    // Exchange state
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
    address insuranceFundWallet;
    address oracleWallet;
  }

  function liquidateWallet(
    LiquidateWalletArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal {
    // FIXME Do not allow liquidation of insurance or exit funds
    // FIXME Allow liquidation of exited wallets without margin check

    (
      int64 totalAccountValueInPips,
      uint64 totalMaintenanceMarginRequirementInPips
    ) = Margin.loadAndValidateTotalAccountValueAndMaintenanceMarginRequirement(
        Margin.LoadArguments(
          arguments.liquidatingWallet,
          arguments.liquidatingWalletOraclePrices,
          arguments.oracleWallet,
          arguments.quoteAssetDecimals,
          arguments.quoteAssetSymbol
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
      );

    string[]
      memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
        arguments.liquidatingWallet
      ];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      liquidatePosition(
        LiquidatePositionArguments(
          arguments.insuranceFundWallet,
          arguments.liquidatingWallet,
          balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
            arguments.liquidatingWallet,
            baseAssetSymbols[i]
          ),
          arguments.liquidationQuoteQuantitiesInPips[i],
          marketsByBaseAssetSymbol[baseAssetSymbols[i]],
          arguments.liquidatingWalletOraclePrices[i],
          arguments.oracleWallet,
          arguments.quoteAssetDecimals,
          arguments.quoteAssetSymbol,
          totalAccountValueInPips,
          totalMaintenanceMarginRequirementInPips
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet
      );
    }

    balanceTracking.updateQuoteForLiquidation(
      arguments.quoteAssetSymbol,
      arguments.insuranceFundWallet,
      arguments.liquidatingWallet
    );

    // Validate that the Insurance Fund still meets its initial margin requirements
    Margin.loadAndValidateTotalAccountValueAndInitialMarginRequirement(
      Margin.LoadArguments(
        arguments.insuranceFundWallet,
        arguments.insuranceFundOraclePrices,
        arguments.oracleWallet,
        arguments.quoteAssetDecimals,
        arguments.quoteAssetSymbol
      ),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function liquidationAcquisitionDeleverage(
    LiquidationAcquisitionDeleverageArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal {
    (
      Market memory market,
      OraclePrice memory oraclePrice
    ) = loadMarketAndOraclePrice(
        arguments,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      );

    // Validate that the liquidating account has fallen below margin requirements
    (
      int64 totalAccountValueInPips,
      uint64 totalMaintenanceMarginRequirementInPips
    ) = Margin.loadAndValidateTotalAccountValueAndMaintenanceMarginRequirement(
        Margin.LoadArguments(
          arguments.liquidatingWallet,
          arguments.liquidatingWalletOraclePrices,
          arguments.oracleWallet,
          arguments.quoteAssetDecimals,
          arguments.quoteAssetSymbol
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
      );

    // Do not proceed with deleverage if the Insurance Fund can acquire the wallet's positions
    validateInsuranceFundCannotLiquidateWallet(
      arguments,
      totalAccountValueInPips,
      totalMaintenanceMarginRequirementInPips,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    // Liquidate specified position by deleveraging a counterparty position at the liquidating wallet's bankruptcy price
    liquidatePosition(
      LiquidatePositionArguments(
        arguments.deleveragingWallet,
        arguments.liquidatingWallet,
        arguments.liquidationBaseQuantityInPips,
        arguments.liquidationQuoteQuantityInPips,
        market,
        oraclePrice,
        arguments.oracleWallet,
        arguments.quoteAssetDecimals,
        arguments.quoteAssetSymbol,
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips
      ),
      balanceTracking,
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
      marketsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function liquidationClosureDeleverage(
    LiquidationClosureDeleverageArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal {
    // Validate that the liquidation price is within 1 pip of the cost basis for position
    int64 expectedLiquidationQuoteQuantitiesInPips = balanceTracking
      .loadBalanceAndMigrateIfNeeded(
        arguments.insuranceFundWallet,
        arguments.baseAssetSymbol
      )
      .costBasisInPips;
    require(
      expectedLiquidationQuoteQuantitiesInPips - 1 <=
        arguments.liquidationQuoteQuantityInPips &&
        expectedLiquidationQuoteQuantitiesInPips + 1 >=
        arguments.liquidationQuoteQuantityInPips,
      'Invalid liquidation quote quantity'
    );

    balanceTracking.updatePositionForLiquidation(
      arguments.liquidationBaseQuantityInPips,
      arguments.deleveragingWallet,
      arguments.insuranceFundWallet,
      loadMarket(
        arguments,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      ),
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
      marketsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function liquidatePosition(
    LiquidatePositionArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    uint64 oraclePriceInPips = Validations.validateOraclePriceAndConvertToPips(
      arguments.oraclePrice,
      arguments.quoteAssetDecimals,
      arguments.market,
      arguments.oracleWallet
    );

    LiquidationValidations.validateLiquidationQuoteQuantity(
      arguments.liquidationQuoteQuantityInPips,
      arguments
        .market
        .loadMarketWithOverridesForWallet(
          arguments.liquidatingWallet,
          marketOverridesByBaseAssetSymbolAndWallet
        )
        .maintenanceMarginFractionInPips,
      oraclePriceInPips,
      arguments.liquidationBaseQuantityInPips,
      arguments.totalAccountValueInPips,
      arguments.totalMaintenanceMarginRequirementInPips
    );

    balanceTracking.updatePositionForLiquidation(
      arguments.liquidationBaseQuantityInPips,
      arguments.counterpartyWallet,
      arguments.liquidatingWallet,
      arguments.market,
      arguments.quoteAssetSymbol,
      arguments.liquidationQuoteQuantityInPips,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function loadMarketAndOraclePrice(
    LiquidationAcquisitionDeleverageArguments memory arguments,
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

  function loadMarket(
    LiquidationClosureDeleverageArguments memory arguments,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (Market memory market) {
    string[]
      memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
        arguments.insuranceFundWallet
      ];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      if (String.isEqual(baseAssetSymbols[i], arguments.baseAssetSymbol)) {
        market = marketsByBaseAssetSymbol[arguments.baseAssetSymbol];
      }
    }

    require(market.exists, 'Invalid market');
  }

  function validateInsuranceFundCannotLiquidateWallet(
    LiquidationAcquisitionDeleverageArguments memory arguments,
    int64 liquidatingWalletTotalAccountValueInPips,
    uint64 liquidatingWalletTotalMaintenanceMarginRequirementInPips,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
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
    }

    Margin.validateInsuranceFundCannotLiquidateWallet(
      loadArguments,
      balanceTracking,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }
}
