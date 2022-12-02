// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { AssetUnitConversions } from "./AssetUnitConversions.sol";
import { Constants } from "./Constants.sol";
import { Hashing } from "./Hashing.sol";
import { String } from "./String.sol";
import { Market, IndexPrice, Withdrawal } from "./Structs.sol";

library Validations {
  function isFeeQuantityValid(uint64 fee, uint64 total) internal pure returns (bool) {
    uint64 feeMultiplier = (fee * Constants.PIP_PRICE_MULTIPLIER) / total;
    return feeMultiplier <= Constants.MAX_FEE_MULTIPLIER;
  }

  function validateAndUpdateIndexPrice(
    Market storage market,
    IndexPrice memory indexPrice,
    address[] memory indexPriceCollectionServiceWallets
  ) internal {
    validateIndexPrice(indexPrice, market, indexPriceCollectionServiceWallets);

    market.lastIndexPriceTimestampInMs = indexPrice.timestampInMs;
  }

  function validateIndexPrice(
    IndexPrice memory indexPrice,
    Market memory market,
    address[] memory indexPriceCollectionServiceWallets
  ) internal pure {
    require(String.isEqual(market.baseAssetSymbol, indexPrice.baseAssetSymbol), "Index price mismatch");

    require(market.lastIndexPriceTimestampInMs <= indexPrice.timestampInMs, "Outdated index price");

    validateIndexPriceSignature(indexPrice, indexPriceCollectionServiceWallets);
  }

  function validateIndexPriceSignature(
    IndexPrice memory indexPrice,
    address[] memory indexPriceCollectionServiceWallets
  ) internal pure {
    bytes32 indexPriceHash = Hashing.getIndexPriceHash(indexPrice);

    address signer = Hashing.getSigner(indexPriceHash, indexPrice.signature);
    bool isSignatureValid = false;
    for (uint8 i = 0; i < indexPriceCollectionServiceWallets.length; i++) {
      isSignatureValid = isSignatureValid || signer == indexPriceCollectionServiceWallets[i];
    }
    require(isSignatureValid, "Invalid index signature");
  }
}
