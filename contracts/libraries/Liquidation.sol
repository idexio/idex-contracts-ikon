// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.15;

import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { LiquidationValidations } from './LiquidationValidations.sol';
import { Margin } from './Margin.sol';
import { String } from './String.sol';
import { Validations } from './Validations.sol';
import { Balance, Market, OraclePrice } from './Structs.sol';

library Liquidation {
  using BalanceTracking for BalanceTracking.Storage;

  struct LiquidationAcquisitionDeleverageArguments {
    // External arguments
    string baseAssetSymbol;
    address deleveragingWallet;
    address liquidatingWallet;
    int64 liquidationQuoteQuantityInPips;
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
    int64 liquidationQuoteQuantityInPips;
    OraclePrice[] deleveragingWalletOraclePrices; // After acquiring IF positions
    // Exchange state
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
    address insuranceFundWallet;
    address oracleWallet;
  }

  struct LiquidatePositionArguments {
    address counterpartyWallet;
    address liquidatingWallet;
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

    string[] memory marketSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
      arguments.liquidatingWallet
    ];
    for (uint8 i = 0; i < marketSymbols.length; i++) {
      liquidatePosition(
        LiquidatePositionArguments(
          arguments.insuranceFundWallet,
          arguments.liquidatingWallet,
          arguments.liquidationQuoteQuantitiesInPips[i],
          marketsByBaseAssetSymbol[marketSymbols[i]],
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
      arguments.baseAssetSymbol,
      arguments.quoteAssetSymbol,
      arguments.deleveragingWallet,
      arguments.insuranceFundWallet,
      arguments.liquidationQuoteQuantityInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
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
    int64 positionSizeInPips = balanceTracking
      .loadBalanceAndMigrateIfNeeded(
        arguments.liquidatingWallet,
        arguments.market.baseAssetSymbol
      )
      .balanceInPips;

    uint64 oraclePriceInPips = Validations.validateOraclePriceAndConvertToPips(
      arguments.oraclePrice,
      arguments.quoteAssetDecimals,
      arguments.market,
      arguments.oracleWallet
    );

    LiquidationValidations.validateLiquidationQuoteQuantity(
      arguments.liquidationQuoteQuantityInPips,
      Margin.loadMaintenanceMarginFractionInPips(
        arguments.market,
        arguments.liquidatingWallet,
        marketOverridesByBaseAssetSymbolAndWallet
      ),
      oraclePriceInPips,
      positionSizeInPips,
      arguments.totalAccountValueInPips,
      arguments.totalMaintenanceMarginRequirementInPips
    );

    balanceTracking.updatePositionForLiquidation(
      arguments.market.baseAssetSymbol,
      arguments.quoteAssetSymbol,
      arguments.counterpartyWallet,
      arguments.liquidatingWallet,
      arguments.liquidationQuoteQuantityInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
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
    string[] memory marketSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
      arguments.liquidatingWallet
    ];
    for (uint8 i = 0; i < marketSymbols.length; i++) {
      if (String.isEqual(marketSymbols[i], arguments.baseAssetSymbol)) {
        market = marketsByBaseAssetSymbol[arguments.baseAssetSymbol];
        oraclePrice = arguments.liquidatingWalletOraclePrices[i];
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
    /*
    require(
      totalAccountValueInPips < int64(totalInitialMarginRequirementInPips),
      'Insurance fund can acquire'
    );

    (
      Balance storage insuranceFundQuoteBalance,
      Balance storage insuranceFundPosition,
      int64 liquidatingPositionSizeInPips
    ) = (
        balanceTracking.loadBalanceAndMigrateIfNeeded(
          deleverageArguments.insuranceFundWallet,
          deleverageArguments.quoteAssetSymbol
        ),
        balanceTracking.loadBalanceAndMigrateIfNeeded(
          deleverageArguments.insuranceFundWallet,
          deleverageArguments.baseAssetSymbol
        ),
        balanceTracking
          .loadBalanceAndMigrateIfNeeded(
            deleverageArguments.liquidatingWallet,
            deleverageArguments.baseAssetSymbol
          )
          .balanceInPips
      );

    // Temporarily update IF balances for margin check
    insuranceFundQuoteBalance.balanceInPips -= deleverageArguments
      .liquidationQuoteQuantityInPips;
    insuranceFundPosition.balanceInPips += liquidatingPositionSizeInPips;
    BalanceTracking.updateOpenPositionsForWallet(
      deleverageArguments.insuranceFundWallet,
      deleverageArguments.baseAssetSymbol,
      insuranceFundPosition.balanceInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    int64 totalAccountValueInPips = Margin.loadTotalAccountValue(
      marginArguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );
    uint64 totalInitialMarginRequirementInPips = Margin
      .loadTotalInitialMarginRequirementAndUpdateLastOraclePrice(
        marginArguments,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
      );
    require(
      totalAccountValueInPips < int64(totalInitialMarginRequirementInPips),
      'Insurance fund can acquire'
    );

    // Revert IF balance updates following margin check
    insuranceFundQuoteBalance.balanceInPips += deleverageArguments
      .liquidationQuoteQuantityInPips;
    insuranceFundPosition.balanceInPips -= liquidatingPositionSizeInPips;
    BalanceTracking.updateOpenPositionsForWallet(
      deleverageArguments.insuranceFundWallet,
      deleverageArguments.baseAssetSymbol,
      insuranceFundPosition.balanceInPips,
      baseAssetSymbolsWithOpenPositionsByWallet
    );
     */
  }
}
