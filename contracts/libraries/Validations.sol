// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.13;

import { Constants } from './Constants.sol';
import { Hashing } from './Hashing.sol';
import { OraclePrice, Withdrawal } from './Structs.sol';

library Validations {
  function isFeeQuantityValid(
    uint64 fee,
    uint64 total,
    uint64 max
  ) internal pure returns (bool) {
    uint64 feeBasisPoints = (fee * Constants.basisPointsInTotal) / total;
    return feeBasisPoints <= max;
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
