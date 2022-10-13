// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { ECDSA } from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

import { Constants } from './Constants.sol';
import { OrderType } from './Enums.sol';
import { DelegatedKeyAuthorization, OraclePrice, Order, Withdrawal } from './Structs.sol';

/**
 * @notice Library helpers for building hashes and verifying wallet signatures
 */
library Hashing {
  function isSignatureValid(
    bytes32 hash,
    bytes memory signature,
    address signer
  ) internal pure returns (bool) {
    return
      ECDSA.recover(ECDSA.toEthSignedMessageHash(hash), signature) == signer;
  }

  function getDelegatedKeyHash(
    address wallet,
    DelegatedKeyAuthorization memory delegatedKeyAuthorization
  ) internal pure returns (bytes32) {
    return
      keccak256(
        abi.encodePacked(
          delegatedKeyAuthorization.nonce,
          wallet,
          delegatedKeyAuthorization.delegatedPublicKey
        )
      );
  }

  function getOraclePriceHash(OraclePrice memory oraclePrice)
    internal
    pure
    returns (bytes32)
  {
    return
      keccak256(
        abi.encodePacked(
          oraclePrice.baseAssetSymbol,
          oraclePrice.timestampInMs,
          oraclePrice.priceInAssetUnits
        )
      );
  }

  /**
   * @dev As a gas optimization, base and quote symbols are passed in separately and combined to
   * verify the wallet hash, since this is cheaper than splitting the market symbol into its two
   * constituent asset symbols
   */
  function getOrderHash(
    Order memory order,
    string memory baseSymbol,
    string memory quoteSymbol
  ) internal pure returns (bytes32) {
    require(
      order.signatureHashVersion == Constants.signatureHashVersion,
      'Signature hash version invalid'
    );
    // Placing all the fields in a single `abi.encodePacked` call causes a `stack too deep` error
    return
      keccak256(
        abi.encodePacked(
          abi.encodePacked(
            order.signatureHashVersion,
            order.nonce,
            order.wallet,
            string(abi.encodePacked(baseSymbol, '-', quoteSymbol)),
            uint8(order.orderType),
            uint8(order.side),
            // Ledger qtys and prices are in pip, but order was signed by wallet owner with decimal
            // values
            pipToDecimal(order.quantityInPips)
          ),
          abi.encodePacked(
            order.isQuantityInQuote,
            order.limitPriceInPips > 0
              ? pipToDecimal(order.limitPriceInPips)
              : '',
            order.triggerPriceInPips > 0
              ? pipToDecimal(order.triggerPriceInPips)
              : '',
            order.triggerPriceInPips > 0
              ? abi.encodePacked(order.triggerType)
              : new bytes(0),
            order.orderType == OrderType.TrailingStop
              ? pipToDecimal(order.callbackRateInPips)
              : '',
            order.conditionalOrderId > 0
              ? abi.encodePacked(order.conditionalOrderId)
              : new bytes(0),
            order.clientOrderId,
            order.isReduceOnly,
            uint8(order.timeInForce),
            uint8(order.selfTradePrevention)
          ),
          order.isSignedByDelegatedKey
            ? abi.encodePacked(
              order.delegatedKeyAuthorization.delegatedPublicKey
            )
            : abi.encodePacked('')
        )
      );
  }

  function getWithdrawalHash(Withdrawal memory withdrawal)
    internal
    pure
    returns (bytes32)
  {
    return
      keccak256(
        abi.encodePacked(
          withdrawal.nonce,
          withdrawal.wallet,
          pipToDecimal(withdrawal.grossQuantityInPips)
        )
      );
  }

  /**
   * @dev Converts an integer pip quantity back into the fixed-precision decimal pip string
   * originally signed by the wallet. For example, 1234567890 becomes '12.34567890'
   */
  function pipToDecimal(uint256 pips) private pure returns (string memory) {
    // Inspired by https://github.com/provable-things/ethereum-api/blob/831f4123816f7a3e57ebea171a3cdcf3b528e475/oraclizeAPI_0.5.sol#L1045-L1062
    uint256 copy = pips;
    uint256 length;
    while (copy != 0) {
      length++;
      copy /= 10;
    }
    if (length < 9) {
      length = 9; // a zero before the decimal point plus 8 decimals
    }
    length++; // for the decimal point

    bytes memory decimal = new bytes(length);
    for (uint256 i = length; i > 0; i--) {
      if (length - i == 8) {
        decimal[i - 1] = bytes1(uint8(46)); // period
      } else {
        decimal[i - 1] = bytes1(uint8(48 + (pips % 10)));
        pips /= 10;
      }
    }
    return string(decimal);
  }
}
