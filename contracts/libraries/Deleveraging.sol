// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { IndexPrice, Market } from "./Structs.sol";

library Deleveraging {
  using SortedStringSet for string[];

  function loadAndValidateMarket(
    string memory baseAssetSymbol,
    address liquidatingWallet,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (Market memory market) {
    market = marketsByBaseAssetSymbol[baseAssetSymbol];
    require(market.exists && market.isActive, "No active market found");

    uint256 i = baseAssetSymbolsWithOpenPositionsByWallet[liquidatingWallet].indexOf(baseAssetSymbol);
    require(i != SortedStringSet.NOT_FOUND, "Open position not found for market");
  }
}
