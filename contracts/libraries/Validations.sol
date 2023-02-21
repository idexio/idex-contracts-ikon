// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Constants } from "./Constants.sol";
import { Market } from "./Structs.sol";
import { Math } from "./Math.sol";
import { SortedStringSet } from "./SortedStringSet.sol";

library Validations {
  using SortedStringSet for string[];

  function isFeeQuantityValid(uint64 fee, uint64 total) internal pure returns (bool) {
    uint64 feeMultiplier = Math.multiplyPipsByFraction(fee, Constants.PIP_PRICE_MULTIPLIER, total);

    return feeMultiplier <= Constants.MAX_FEE_MULTIPLIER;
  }

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
