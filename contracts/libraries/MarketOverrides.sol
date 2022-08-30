// SPDX-License-Identifier: LGPL-3.0-only

import { Market } from './Structs.sol';

pragma solidity 0.8.15;

library MarketOverrides {
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
