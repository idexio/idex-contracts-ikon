// SPDX-License-Identifier: LGPL-3.0-only

import { Market } from './Structs.sol';
import { Math } from './Math.sol';

pragma solidity 0.8.15;

library MarketOverrides {
  function loadInitialMarginFractionInPipsForWallet(
    Market memory defaultMarket,
    int64 positionSizeInPips,
    address wallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal view returns (uint64) {
    Market memory marketWithOverrides = loadMarketWithOverridesForWallet(
      defaultMarket,
      wallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    uint64 absolutePositionSizeInPips = Math.abs(positionSizeInPips);
    if (
      absolutePositionSizeInPips <=
      marketWithOverrides.baselinePositionSizeInPips
    ) {
      return marketWithOverrides.initialMarginFractionInPips;
    }

    uint64 increments = (absolutePositionSizeInPips -
      marketWithOverrides.baselinePositionSizeInPips) /
      marketWithOverrides.incrementalPositionSizeInPips;
    return
      marketWithOverrides.initialMarginFractionInPips +
      (increments * marketWithOverrides.incrementalInitialMarginFractionInPips);
  }

  function loadMarketWithOverridesForWallet(
    Market memory defaultMarket,
    address wallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal view returns (Market memory market) {
    Market memory overrideMarket = marketOverridesByBaseAssetSymbolAndWallet[
      defaultMarket.baseAssetSymbol
    ][wallet];
    if (overrideMarket.exists) {
      return overrideMarket;
    }

    return defaultMarket;
  }
}
