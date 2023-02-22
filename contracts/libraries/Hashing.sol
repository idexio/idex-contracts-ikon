// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { Constants } from "./Constants.sol";
import { OrderType } from "./Enums.sol";
import { DelegatedKeyAuthorization, IndexPrice, Order, Transfer, Withdrawal } from "./Structs.sol";

/**
 * @notice Library helpers for building hashes and verifying wallet signatures
 */
library Hashing {
  function getSigner(bytes32 hash, bytes memory signature) internal pure returns (address) {
    return ECDSA.recover(ECDSA.toEthSignedMessageHash(hash), signature);
  }

  function isSignatureValid(bytes memory message, bytes memory signature, address signer) internal pure returns (bool) {
    return ECDSA.recover(ECDSA.toEthSignedMessageHash(message), signature) == signer;
  }

  function isSignatureValid(bytes32 hash, bytes memory signature, address signer) internal pure returns (bool) {
    return getSigner(hash, signature) == signer;
  }

  function getDelegatedKeyMessage(
    DelegatedKeyAuthorization memory delegatedKeyAuthorization
  ) internal pure returns (bytes memory) {
    require(
      delegatedKeyAuthorization.signatureHashVersion == Constants.SIGNATURE_HASH_VERSION,
      "Signature hash version invalid"
    );

    return
      abi.encodePacked(
        delegatedKeyAuthorization.signatureHashVersion,
        Constants.ENCODED_DELEGATE_KEY_SIGNATURE_MESSAGE,
        Strings.toString(uint160(delegatedKeyAuthorization.delegatedPublicKey)),
        Strings.toString(delegatedKeyAuthorization.nonce)
      );
  }

  function getIndexPriceHash(IndexPrice memory indexPrice) internal pure returns (bytes32) {
    require(indexPrice.signatureHashVersion == Constants.SIGNATURE_HASH_VERSION, "Signature hash version invalid");

    return
      keccak256(
        abi.encodePacked(
          indexPrice.signatureHashVersion,
          indexPrice.baseAssetSymbol,
          Constants.QUOTE_ASSET_SYMBOL,
          indexPrice.timestampInMs,
          _pipToDecimal(indexPrice.price)
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
    require(order.signatureHashVersion == Constants.SIGNATURE_HASH_VERSION, "Signature hash version invalid");
    // Placing all the fields in a single `abi.encodePacked` call causes a `stack too deep` error
    return
      keccak256(
        abi.encodePacked(
          abi.encodePacked(
            order.signatureHashVersion,
            order.nonce,
            order.wallet,
            string(abi.encodePacked(baseSymbol, "-", quoteSymbol)),
            uint8(order.orderType),
            uint8(order.side),
            // Ledger qtys and prices are in pip, but order was signed by wallet owner with decimal
            // values
            _pipToDecimal(order.quantity)
          ),
          abi.encodePacked(
            order.limitPrice > 0 ? _pipToDecimal(order.limitPrice) : Constants.EMPTY_DECIMAL_STRING,
            order.triggerPrice > 0 ? _pipToDecimal(order.triggerPrice) : Constants.EMPTY_DECIMAL_STRING,
            order.triggerType,
            order.orderType == OrderType.TrailingStop
              ? _pipToDecimal(order.callbackRate)
              : Constants.EMPTY_DECIMAL_STRING,
            order.conditionalOrderId,
            order.isReduceOnly,
            uint8(order.timeInForce),
            uint8(order.selfTradePrevention)
          ),
          order.delegatedKeyAuthorization.delegatedPublicKey,
          order.clientOrderId
        )
      );
  }

  function getTransferHash(Transfer memory transfer) internal pure returns (bytes32) {
    require(transfer.signatureHashVersion == Constants.SIGNATURE_HASH_VERSION, "Signature hash version invalid");

    return
      keccak256(
        abi.encodePacked(
          transfer.signatureHashVersion,
          transfer.nonce,
          transfer.sourceWallet,
          transfer.destinationWallet,
          _pipToDecimal(transfer.grossQuantity)
        )
      );
  }

  function getWithdrawalHash(Withdrawal memory withdrawal) internal pure returns (bytes32) {
    require(withdrawal.signatureHashVersion == Constants.SIGNATURE_HASH_VERSION, "Signature hash version invalid");

    return
      keccak256(
        abi.encodePacked(
          withdrawal.signatureHashVersion,
          withdrawal.nonce,
          withdrawal.wallet,
          _pipToDecimal(withdrawal.grossQuantity),
          withdrawal.targetChain
        )
      );
  }

  /**
   * @dev Converts an integer pip quantity back into the fixed-precision decimal pip string
   * originally signed by the wallet. For example, 1234567890 becomes '12.34567890'
   */
  function _pipToDecimal(uint256 pips) private pure returns (string memory) {
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
