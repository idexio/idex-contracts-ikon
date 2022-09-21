// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

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

  function validateAndUpdateOraclePriceAndConvertToPips(
    OraclePrice memory oraclePrice,
    uint8 quoteAssetDecimals,
    Market storage market,
    address oracleWallet
  ) internal returns (uint64) {
    market.lastOraclePriceTimestampInMs = oraclePrice.timestampInMs;

    return
      validateOraclePriceAndConvertToPips(
        oraclePrice,
        quoteAssetDecimals,
        market,
        oracleWallet
      );
  }

  function validateOraclePriceAndConvertToPips(
    OraclePrice memory oraclePrice,
    uint8 quoteAssetDecimals,
    Market memory market,
    address oracleWallet
  ) internal pure returns (uint64) {
    require(
      String.isEqual(market.baseAssetSymbol, oraclePrice.baseAssetSymbol),
      'Oracle price mismatch'
    );

    require(
      market.lastOraclePriceTimestampInMs <= oraclePrice.timestampInMs,
      'Outdated oracle price'
    );

    return
      validateOraclePriceAndConvertToPips(
        oraclePrice,
        quoteAssetDecimals,
        oracleWallet
      );
  }

  function validateOraclePriceAndConvertToPips(
    OraclePrice memory oraclePrice,
    uint8 quoteAssetDecimals,
    address oracleWallet
  ) internal pure returns (uint64) {
    // TODO Validate timestamp recency
    validateOraclePriceSignature(oraclePrice, oracleWallet);

    return
      AssetUnitConversions.assetUnitsToPips(
        oraclePrice.priceInAssetUnits,
        quoteAssetDecimals
      );
  }

  function validateOraclePriceSignature(
    OraclePrice memory oraclePrice,
    address oracleWallet
  ) internal pure returns (bytes32) {
    bytes32 oraclePriceHash = Hashing.getOraclePriceHash(oraclePrice);

    require(
      Hashing.isSignatureValid(
        oraclePriceHash,
        oraclePrice.signature,
        oracleWallet
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
