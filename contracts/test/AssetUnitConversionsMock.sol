// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { AssetUnitConversions } from "../libraries/AssetUnitConversions.sol";

contract AssetUnitConversionsMock {
  function pipsToAssetUnits(uint64 quantityInPips, uint8 assetDecimals) external pure returns (uint256) {
    return AssetUnitConversions.pipsToAssetUnits(quantityInPips, assetDecimals);
  }

  function assetUnitsToPips(uint256 quantityInAssetUnits, uint8 assetDecimals) external pure returns (uint64) {
    return AssetUnitConversions.assetUnitsToPips(quantityInAssetUnits, assetDecimals);
  }
}
