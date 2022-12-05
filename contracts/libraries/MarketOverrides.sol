// SPDX-License-Identifier: LGPL-3.0-only

import { Market } from "./Structs.sol";
import { Math } from "./Math.sol";

pragma solidity 0.8.17;

library MarketOverrides {
  function loadInitialMarginFractionForWallet(
    Market memory defaultMarket,
    int64 positionSize,
    address wallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal view returns (uint64) {
    Market memory marketWithOverrides = loadMarketWithOverridesForWallet(
      defaultMarket,
      wallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    uint64 absolutePositionSize = Math.abs(positionSize);
    if (absolutePositionSize <= marketWithOverrides.baselinePositionSize) {
      return marketWithOverrides.initialMarginFraction;
    }

    uint64 increments = (absolutePositionSize - marketWithOverrides.baselinePositionSize) /
      marketWithOverrides.incrementalPositionSize;
    return
      marketWithOverrides.initialMarginFraction + (increments * marketWithOverrides.incrementalInitialMarginFraction);
  }

  function loadMarketWithOverridesForWallet(
    Market memory defaultMarket,
    address wallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal view returns (Market memory market) {
    Market memory overrideMarket = marketOverridesByBaseAssetSymbolAndWallet[defaultMarket.baseAssetSymbol][wallet];
    if (overrideMarket.exists) {
      return overrideMarket;
    }

    return defaultMarket;
  }
}
