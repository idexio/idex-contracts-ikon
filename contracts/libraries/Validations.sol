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
    address indexPriceCollectionServiceWallet
  ) internal returns (uint64) {
    market.lastIndexPriceTimestampInMs = indexPrice.timestampInMs;

    return validateIndexPrice(indexPrice, market, indexPriceCollectionServiceWallet);
  }

  function validateIndexPrice(
    IndexPrice memory indexPrice,
    Market memory market,
    address indexPriceCollectionServiceWallet
  ) internal pure returns (uint64) {
    require(String.isEqual(market.baseAssetSymbol, indexPrice.baseAssetSymbol), "Index price mismatch");

    require(market.lastIndexPriceTimestampInMs <= indexPrice.timestampInMs, "Outdated index price");

    validateIndexPriceSignature(indexPrice, indexPriceCollectionServiceWallet);
  }

  function validateIndexPriceSignature(
    IndexPrice memory indexPrice,
    address indexPriceCollectionServiceWallet
  ) internal pure returns (bytes32) {
    bytes32 indexPriceHash = Hashing.getIndexPriceHash(indexPrice);

    require(
      Hashing.isSignatureValid(indexPriceHash, indexPrice.signature, indexPriceCollectionServiceWallet),
      "Invalid index signature"
    );

    return indexPriceHash;
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
