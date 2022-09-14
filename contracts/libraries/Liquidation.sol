// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.15;

import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { LiquidationType } from './Enums.sol';
import { LiquidationValidations } from './LiquidationValidations.sol';
import { Margin } from './Margin.sol';
import { Math } from './Math.sol';
import { MarketOverrides } from './MarketOverrides.sol';
import { String } from './String.sol';
import { SortedStringSet } from './SortedStringSet.sol';
import { Validations } from './Validations.sol';
import { Balance, Market, OraclePrice } from './Structs.sol';

library Liquidation {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketOverrides for Market;
  using SortedStringSet for string[];

  struct LiquidateDustPositionArguments {
    // External arguments
    string baseAssetSymbol;
    address liquidatingWallet;
    int64 liquidationQuoteQuantityInPips; // For the position being liquidated
    OraclePrice[] insuranceFundOraclePrices; // After acquiring liquidating position
    OraclePrice[] liquidatingWalletOraclePrices; // Before liquidation
    // Exchange state
    uint64 dustPositionLiquidationPriceToleranceBasisPoints;
    address insuranceFundWallet;
    address oracleWallet;
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
  }

  struct LiquidatePositionArguments {
    LiquidationType liquidationType;
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
    LiquidationType liquidationType;
    address counterpartyWallet; // Insurance Fund or Exit Fund
    OraclePrice[] counterpartyWalletOraclePrices; // After acquiring liquidated positions
    address liquidatingWallet;
    OraclePrice[] liquidatingWalletOraclePrices;
    int64[] liquidationQuoteQuantitiesInPips;
    // Exchange state
    address oracleWallet;
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
  }

  struct LiquidationAcquisitionDeleverageArguments {
    // External arguments
    LiquidationType liquidationType;
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

  function liquidateDustPosition(
    LiquidateDustPositionArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal {
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
    require(
      totalAccountValueInPips >= int64(totalMaintenanceMarginRequirementInPips),
      'Maintenance margin requirement not met'
    );

    (
      Market memory market,
      OraclePrice memory oraclePrice
    ) = loadMarketAndOraclePrice(
        arguments,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      );

    int64 positionSizeInPips = balanceTracking
      .loadBalanceInPipsFromMigrationSourceIfNeeded(
        arguments.liquidatingWallet,
        arguments.baseAssetSymbol
      );
    require(
      Math.abs(positionSizeInPips) <
        market
          .loadMarketWithOverridesForWallet(
            arguments.liquidatingWallet,
            marketOverridesByBaseAssetSymbolAndWallet
          )
          .minimumPositionSizeInPips,
      'Position size above minimum'
    );

    uint64 oraclePriceInPips = Validations.validateOraclePriceAndConvertToPips(
      oraclePrice,
      arguments.quoteAssetDecimals,
      market,
      arguments.oracleWallet
    );
    LiquidationValidations.validateDustLiquidationQuoteQuantity(
      arguments.dustPositionLiquidationPriceToleranceBasisPoints,
      arguments.liquidationQuoteQuantityInPips,
      oraclePriceInPips,
      positionSizeInPips
    );

    liquidatePosition(
      oraclePriceInPips,
      LiquidatePositionArguments(
        LiquidationType.Dust,
        arguments.insuranceFundWallet,
        arguments.liquidatingWallet,
        positionSizeInPips,
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
    if (
      arguments.liquidationType == LiquidationType.InMaintenance ||
      arguments.liquidationType == LiquidationType.SystemRecovery
    ) {
      require(
        totalAccountValueInPips <
          int64(totalMaintenanceMarginRequirementInPips),
        'Maintenance margin requirement met'
      );
    }

    string[]
      memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
        arguments.liquidatingWallet
      ];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      liquidatePosition(
        LiquidatePositionArguments(
          arguments.liquidationType,
          arguments.counterpartyWallet,
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
      arguments.counterpartyWallet,
      arguments.liquidatingWallet
    );

    if (
      arguments.liquidationType == LiquidationType.Exited ||
      arguments.liquidationType == LiquidationType.InMaintenance
    ) {
      // Validate that the Insurance Fund still meets its initial margin requirements
      Margin.loadAndValidateTotalAccountValueAndInitialMarginRequirement(
        Margin.LoadArguments(
          arguments.counterpartyWallet,
          arguments.counterpartyWalletOraclePrices,
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
    require(
      arguments.liquidationType == LiquidationType.Exited ||
        arguments.liquidationType == LiquidationType.InMaintenance,
      'Unsupported liquidation type'
    );

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
    if (arguments.liquidationType == LiquidationType.InMaintenance) {
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
      marketsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    // Liquidate specified position by deleveraging a counterparty position at the liquidating wallet's bankruptcy price
    liquidatePosition(
      LiquidatePositionArguments(
        arguments.liquidationType,
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

    liquidatePosition(
      oraclePriceInPips,
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function liquidatePosition(
    uint64 oraclePriceInPips,
    LiquidatePositionArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    if (arguments.liquidationType == LiquidationType.InMaintenance) {
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
    } else {
      Balance storage balance = balanceTracking.loadBalanceAndMigrateIfNeeded(
        arguments.liquidatingWallet,
        arguments.market.baseAssetSymbol
      );
      LiquidationValidations.validateExitQuoteQuantity(
        Math.multiplyPipsByFraction(
          balance.costBasisInPips,
          arguments.liquidationBaseQuantityInPips,
          balance.balanceInPips
        ),
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
    }

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
    LiquidateDustPositionArguments memory arguments,
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
      if (arguments.liquidationType == LiquidationType.InMaintenance) {
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
