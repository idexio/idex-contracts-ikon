// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { Constants } from "./Constants.sol";
import { Hashing } from "./Hashing.sol";
import { Math } from "./Math.sol";
import { String } from "./String.sol";
import { Time } from "./Time.sol";
import { Market, IndexPrice } from "./Structs.sol";

library Validations {
  function isFeeQuantityValid(uint64 fee, uint64 total) internal pure returns (bool) {
    uint64 feeMultiplier = Math.multiplyPipsByFraction(fee, Constants.PIP_PRICE_MULTIPLIER, total);

    return feeMultiplier <= Constants.MAX_FEE_MULTIPLIER;
  }

  function validateAndUpdateIndexPrice(
    IndexPrice memory indexPrice,
    address[] memory indexPriceCollectionServiceWallets,
    Market storage market
  ) internal {
    validateIndexPrice(indexPrice, indexPriceCollectionServiceWallets, market);

    market.lastIndexPriceTimestampInMs = indexPrice.timestampInMs;
  }

  function validateIndexPrice(
    IndexPrice memory indexPrice,
    address[] memory indexPriceCollectionServiceWallets,
    Market memory market
  ) internal view {
    require(String.isEqual(market.baseAssetSymbol, indexPrice.baseAssetSymbol), "Index price mismatch");

    require(market.lastIndexPriceTimestampInMs <= indexPrice.timestampInMs, "Outdated index price");

    require(indexPrice.timestampInMs < Time.getOneDayFromNowInMs(), "Index price timestamp too high");

    _validateIndexPriceSignature(indexPrice, indexPriceCollectionServiceWallets);
  }

  function _validateIndexPriceSignature(
    IndexPrice memory indexPrice,
    address[] memory indexPriceCollectionServiceWallets
  ) private pure {
    bytes32 indexPriceHash = Hashing.getIndexPriceHash(indexPrice);

    address signer = Hashing.getSigner(indexPriceHash, indexPrice.signature);
    bool isSignatureValid = false;
    for (uint8 i = 0; i < indexPriceCollectionServiceWallets.length; i++) {
      isSignatureValid = isSignatureValid || signer == indexPriceCollectionServiceWallets[i];
    }
    require(isSignatureValid, "Invalid index signature");
  }
}
