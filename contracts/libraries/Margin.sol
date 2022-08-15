// SPDX-License-Identifier: LGPL-3.0-only

import { AssetUnitConversions } from './AssetUnitConversions.sol';
import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { Math } from './Math.sol';
import { String } from './String.sol';
import { Validations } from './Validations.sol';
import { Market, OraclePrice } from './Structs.sol';

pragma solidity 0.8.15;

library Margin {
  using BalanceTracking for BalanceTracking.Storage;

  struct LoadMarginRequirementArguments {
    address wallet;
    OraclePrice[] oraclePrices;
    address oracleWalletAddress;
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
  }

  function loadTotalAccountValue(
    LoadMarginRequirementArguments memory arguments,
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
    LoadMarginRequirementArguments memory arguments,
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
        market.maintenanceMarginFractionInPips,
        oraclePrice,
        quoteAssetDecimals,
        oracleWalletAddress,
        balanceTracking
      );
    }
  }

  function loadTotalMaintenanceMarginRequirementAndUpdateLastOraclePrice(
    LoadMarginRequirementArguments memory arguments,
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
    LoadMarginRequirementArguments memory arguments,
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
    LoadMarginRequirementArguments memory arguments,
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
