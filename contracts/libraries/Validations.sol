// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { AssetUnitConversions } from "./AssetUnitConversions.sol";
import { Constants } from "./Constants.sol";
import { Hashing } from "./Hashing.sol";
import { String } from "./String.sol";
import { Market, IndexPrice, Withdrawal } from "./Structs.sol";

library Validations {
  function isFeeQuantityValid(uint64 fee, uint64 total, uint64 max) internal pure returns (bool) {
    uint64 feeBasisPoints = (fee * Constants.BASIS_POINTS_IN_TOTAL) / total;
    return feeBasisPoints <= max;
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

  function validateWithdrawalSignature(Withdrawal memory withdrawal) internal pure returns (bytes32) {
    bytes32 withdrawalHash = Hashing.getWithdrawalHash(withdrawal);

    require(
      Hashing.isSignatureValid(withdrawalHash, withdrawal.walletSignature, withdrawal.wallet),
      "Invalid wallet signature"
    );

    return withdrawalHash;
  }
}
