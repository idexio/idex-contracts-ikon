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

  struct DeleveragePositionArguments {
    // External arguments
    string baseAssetSymbol;
    address deleveragingWallet;
    address liquidatingWallet;
    int64 liquidationQuoteQuantityInPips;
    OraclePrice[] deleveragingWalletOraclePrices;
    OraclePrice[] insuranceFundOraclePrices;
    OraclePrice[] liquidatingWalletOraclePrices;
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
    ) = loadAndValidateTotalAccountValueAndMaintenanceMarginRequirement(
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
        baseAssetSymbolsWithOpenPositionsByWallet
      );
    }

    balanceTracking.updateQuoteForLiquidation(
      arguments.quoteAssetSymbol,
      arguments.insuranceFundWallet,
      arguments.liquidatingWallet
    );

    (
      totalAccountValueInPips,
      totalMaintenanceMarginRequirementInPips
    ) = loadAndValidateTotalAccountValueAndInitialMarginRequirement(
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
    DeleveragePositionArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal {
    validateInsuranceFundCannotAcquirePosition(
      arguments,
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

    (
      int64 totalAccountValueInPips,
      uint64 totalMaintenanceMarginRequirementInPips
    ) = loadAndValidateTotalAccountValueAndMaintenanceMarginRequirement(
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

    (
      Market memory market,
      OraclePrice memory oraclePrice
    ) = loadMarketAndOraclePrice(
        arguments,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      );

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
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    loadAndValidateTotalAccountValueAndInitialMarginRequirement(
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
      storage baseAssetSymbolsWithOpenPositionsByWallet
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
      arguments.market.maintenanceMarginFractionInPips,
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

  function loadAndValidateTotalAccountValueAndMaintenanceMarginRequirement(
    Margin.LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  )
    private
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
        marketsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
      );

    require(
      totalAccountValueInPips < int64(totalMaintenanceMarginRequirementInPips),
      'Maintenance margin requirement met'
    );

    return (totalAccountValueInPips, totalMaintenanceMarginRequirementInPips);
  }

  function loadAndValidateTotalAccountValueAndInitialMarginRequirement(
    Margin.LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  )
    private
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

    totalInitialMarginRequirementInPips = Margin
      .loadTotalInitialMarginRequirementAndUpdateLastOraclePrice(
        arguments,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
      );

    require(
      totalAccountValueInPips >= int64(totalInitialMarginRequirementInPips),
      'Initial margin requirement not met'
    );

    return (totalAccountValueInPips, totalInitialMarginRequirementInPips);
  }

  function loadMarketAndOraclePrice(
    DeleveragePositionArguments memory arguments,
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

  function validateInsuranceFundCannotAcquirePosition(
    DeleveragePositionArguments memory deleverageArguments,
    Margin.LoadArguments memory marginArguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
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
  }
}
