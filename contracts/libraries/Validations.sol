// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.13;

import { AssetUnitConversions } from './AssetUnitConversions.sol';
import { Constants } from './Constants.sol';
import { Hashing } from './Hashing.sol';
import { String } from './String.sol';
import { Market, OraclePrice, Withdrawal } from './Structs.sol';

library Validations {
  function isFeeQuantityValid(
    uint64 fee,
    uint64 total,
    uint64 max
  ) internal pure returns (bool) {
    uint64 feeBasisPoints = (fee * Constants.basisPointsInTotal) / total;
    return feeBasisPoints <= max;
  }

  function validateOraclePriceAndConvertToPips(
    OraclePrice memory oraclePrice,
    uint8 collateralAssetDecimals,
    Market memory market,
    address oracleWalletAddress
  ) internal pure returns (uint64) {
    require(
      String.isStringEqual(market.baseAssetSymbol, oraclePrice.baseAssetSymbol),
      'Oracle price mismatch'
    );

    return
      validateOraclePriceAndConvertToPips(
        oraclePrice,
        collateralAssetDecimals,
        oracleWalletAddress
      );
  }

  function validateOraclePriceAndConvertToPips(
    OraclePrice memory oraclePrice,
    uint8 collateralAssetDecimals,
    address oracleWalletAddress
  ) internal pure returns (uint64) {
    // TODO Validate timestamp recency
    validateOraclePriceSignature(oraclePrice, oracleWalletAddress);

    return
      AssetUnitConversions.assetUnitsToPips(
        oraclePrice.priceInAssetUnits,
        collateralAssetDecimals
      );
  }

  function validateOraclePriceSignature(
    OraclePrice memory oraclePrice,
    address oracleWalletAddress
  ) internal pure returns (bytes32) {
    bytes32 oraclePriceHash = Hashing.getOraclePriceHash(oraclePrice);

    require(
      Hashing.isSignatureValid(
        oraclePriceHash,
        oraclePrice.signature,
        oracleWalletAddress
      ),
      'Invalid oracle signature'
    );

    return oraclePriceHash;
  }

  function validateWithdrawalSignature(Withdrawal memory withdrawal)
    internal
    pure
    returns (bytes32)
  {
    bytes32 withdrawalHash = Hashing.getWithdrawalHash(withdrawal);

    require(
      Hashing.isSignatureValid(
        withdrawalHash,
        withdrawal.walletSignature,
        withdrawal.walletAddress
      ),
      'Invalid wallet signature'
    );

    return withdrawalHash;
  }
}
