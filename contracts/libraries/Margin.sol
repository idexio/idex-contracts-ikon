// SPDX-License-Identifier: LGPL-3.0-only

import { AssetUnitConversions } from './AssetUnitConversions.sol';
import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { LiquidationValidations } from './LiquidationValidations.sol';
import { Math } from './Math.sol';
import { String } from './String.sol';
import { StringArray } from './StringArray.sol';
import { Validations } from './Validations.sol';
import { Market, OraclePrice } from './Structs.sol';

pragma solidity 0.8.15;

library Margin {
  using BalanceTracking for BalanceTracking.Storage;
  using StringArray for string[];

  struct LoadArguments {
    address wallet;
    OraclePrice[] oraclePrices;
    address oracleWalletAddress;
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
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
    internal
    returns (
      int64 totalAccountValueInPips,
      uint64 totalMaintenanceMarginRequirementInPips
    )
  {
    (
      totalAccountValueInPips,
      totalMaintenanceMarginRequirementInPips
    ) = loadTotalAccountValueAndMaintenanceMarginRequirement(
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

    string[] memory marketSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
      arguments.wallet
    ];
    for (uint8 i = 0; i < marketSymbols.length; i++) {
      Market memory market = marketsByBaseAssetSymbol[marketSymbols[i]];
      uint64 oraclePriceInPips = Validations
        .validateOraclePriceAndConvertToPips(
          arguments.oraclePrices[i],
          arguments.quoteAssetDecimals,
          market,
          arguments.oracleWalletAddress
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

  function loadTotalAccountValueAndInitialMarginRequirementAfterLiquidationAcquisition(
    Margin.LoadArguments memory arguments,
    address liquidatingWallet,
    int64 liquidatingWalletTotalAccountValueInPips,
    uint64 liquidatingWalletTotalMaintenanceMarginRequirementInPips,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  )
    internal
    returns (
      int64 totalAccountValueInPips,
      uint64 totalInitialMarginRequirementInPips
    )
  {
    string[] memory marketSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
      arguments.wallet
    ].merge(baseAssetSymbolsWithOpenPositionsByWallet[liquidatingWallet]);

    int64 insuranceFundPositionSizeInPips;
    int64 liquidatingWalletPositionSizeInPips;
    uint64 oraclePriceInPips;
    int64 positionValueInPips;
    for (uint8 i = 0; i < marketSymbols.length; i++) {
      // Calculate Insurance Fund position size after acquiring position
      insuranceFundPositionSizeInPips = balanceTracking
        .loadBalanceInPipsFromMigrationSourceIfNeeded(
          arguments.wallet,
          marketSymbols[i]
        );

      liquidatingWalletPositionSizeInPips = balanceTracking
        .loadBalanceInPipsFromMigrationSourceIfNeeded(
          liquidatingWallet,
          marketSymbols[i]
        );
      insuranceFundPositionSizeInPips += liquidatingWalletPositionSizeInPips;

      // If position is non-zero then include in margin check
      if (insuranceFundPositionSizeInPips != 0) {
        Market storage market = marketsByBaseAssetSymbol[marketSymbols[i]];
        oraclePriceInPips = Validations
          .validateAndUpdateOraclePriceAndConvertToPips(
            arguments.oraclePrices[i],
            arguments.quoteAssetDecimals,
            market,
            arguments.oracleWalletAddress
          );
        positionValueInPips = Math.multiplyPipsByFraction(
          insuranceFundPositionSizeInPips,
          int64(oraclePriceInPips),
          int64(Constants.pipPriceMultiplier)
        );

        // Accumulate account value by first adding position value...
        totalAccountValueInPips += positionValueInPips;
        // ... and then subtracting the liquidation quote value
        totalAccountValueInPips -= LiquidationValidations
          .calculateLiquidationQuoteQuantityInPips(
            loadInitialMarginFractionInPips(
              market,
              liquidatingWallet,
              marketOverridesByBaseAssetSymbolAndWallet
            ),
            oraclePriceInPips,
            liquidatingWalletPositionSizeInPips,
            liquidatingWalletTotalAccountValueInPips,
            liquidatingWalletTotalMaintenanceMarginRequirementInPips
          );

        // Accumulate margin requirement
        totalInitialMarginRequirementInPips += Math.abs(
          Math.multiplyPipsByFraction(
            positionValueInPips,
            int64(
              loadInitialMarginFractionInPips(
                market,
                arguments.wallet,
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
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
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
        marketsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
      );
  }

  function loadTotalInitialMarginRequirement(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 quoteAssetDecimals,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet
  ) internal view returns (uint64 initialMarginRequirement) {
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
        market.initialMarginFractionInPips,
        oraclePrice,
        quoteAssetDecimals,
        oracleWalletAddress,
        balanceTracking
      );
    }
  }

  function loadTotalInitialMarginRequirementAndUpdateLastOraclePrice(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
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
        loadInitialMarginFractionInPips(
          market,
          arguments.wallet,
          marketOverridesByBaseAssetSymbolAndWallet
        ),
        oraclePrice,
        balanceTracking
      );
    }
  }

  function loadTotalMaintenanceMarginRequirement(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 quoteAssetDecimals,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet
  ) internal view returns (uint64 maintenanceMarginRequirement) {
    string[] memory marketSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
      wallet
    ];
    for (uint8 i = 0; i < marketSymbols.length; i++) {
      (Market memory market, OraclePrice memory oraclePrice) = (
        marketsByBaseAssetSymbol[marketSymbols[i]],
        oraclePrices[i]
      );

      maintenanceMarginRequirement += loadMarginRequirement(
        wallet,
        market.baseAssetSymbol,
        market.maintenanceMarginFractionInPips,
        oraclePrice,
        quoteAssetDecimals,
        oracleWalletAddress,
        balanceTracking
      );
    }
  }

  function loadTotalMaintenanceMarginRequirementAndUpdateLastOraclePrice(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
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
        loadMaintenanceMarginFractionInPips(
          market,
          arguments.wallet,
          marketOverridesByBaseAssetSymbolAndWallet
        ),
        oraclePrice,
        balanceTracking
      );
    }
  }

  function loadMarginRequirement(
    address wallet,
    string memory baseAssetSymbol,
    uint64 marginFractionInPips,
    OraclePrice memory oraclePrice,
    uint8 quoteAssetDecimals,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking
  ) internal view returns (uint64) {
    require(
      String.isEqual(baseAssetSymbol, oraclePrice.baseAssetSymbol),
      'Oracle price mismatch'
    );
    Validations.validateOraclePriceSignature(oraclePrice, oracleWalletAddress);

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
  ) internal returns (uint64) {
    require(
      String.isEqual(market.baseAssetSymbol, oraclePrice.baseAssetSymbol),
      'Oracle price mismatch'
    );
    uint64 oraclePriceInPips = Validations
      .validateAndUpdateOraclePriceAndConvertToPips(
        oraclePrice,
        arguments.quoteAssetDecimals,
        market,
        arguments.oracleWalletAddress
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

  /**
   * @dev Utterly crass naming
   */
  function isInitialMarginRequirementMetAndUpdateLastOraclePrice(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
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
          marketsByBaseAssetSymbol,
          marketOverridesByBaseAssetSymbolAndWallet
        )
      );
  }

  function loadInitialMarginFractionInPips(
    Market memory market,
    address wallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal view returns (uint64 initialMarginFractionInPips) {
    initialMarginFractionInPips = market.initialMarginFractionInPips;

    Market memory overrideMarket = marketOverridesByBaseAssetSymbolAndWallet[
      market.baseAssetSymbol
    ][wallet];
    if (overrideMarket.exists) {
      initialMarginFractionInPips = overrideMarket.initialMarginFractionInPips;
    }
  }

  function loadMaintenanceMarginFractionInPips(
    Market memory market,
    address wallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal view returns (uint64 maintenanceMarginFractionInPips) {
    maintenanceMarginFractionInPips = market.maintenanceMarginFractionInPips;

    Market memory overrideMarket = marketOverridesByBaseAssetSymbolAndWallet[
      market.baseAssetSymbol
    ][wallet];
    if (overrideMarket.exists) {
      maintenanceMarginFractionInPips = overrideMarket
        .maintenanceMarginFractionInPips;
    }
  }
}
