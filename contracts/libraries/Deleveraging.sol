// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { IndexPrice, Market } from "./Structs.sol";

library Deleveraging {
  using SortedStringSet for string[];

  function loadAndValidateMarketAndIndexPrice(
    string memory baseAssetSymbol,
    address[] memory indexPriceCollectionServiceWallets,
    address liquidatingWallet,
    IndexPrice[] memory indexPrices,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (Market memory market, IndexPrice memory indexPrice) {
    market = marketsByBaseAssetSymbol[baseAssetSymbol];
    require(market.exists && market.isActive, "No active market found");

    uint256 i = baseAssetSymbolsWithOpenPositionsByWallet[liquidatingWallet].indexOf(baseAssetSymbol);
    require(i != SortedStringSet.NOT_FOUND, "Index price not found for market");

    indexPrice = indexPrices[i];

    Validations.validateIndexPrice(indexPrice, indexPriceCollectionServiceWallets, market);
  }
}
