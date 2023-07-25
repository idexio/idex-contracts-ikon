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
  function getSigner(
    bytes32 domainSeparator,
    bytes32 structHash,
    bytes memory signature
  ) internal pure returns (address) {
    return ECDSA.recover(ECDSA.toTypedDataHash(domainSeparator, structHash), signature);
  }

  function isSignatureValid(
    bytes32 domainSeparator,
    bytes32 structHash,
    bytes memory signature,
    address signer
  ) internal pure returns (bool) {
    return getSigner(domainSeparator, structHash, signature) == signer;
  }

  function getDelegatedKeyAuthorizationHash(
    DelegatedKeyAuthorization memory delegatedKeyAuthorization
  ) internal pure returns (bytes32) {
    return
      keccak256(
        abi.encode(
          Constants.EIP_712_TYPE_HASH_DELEGATED_KEY_AUTHORIZATION,
          delegatedKeyAuthorization.nonce,
          delegatedKeyAuthorization.delegatedPublicKey,
          Constants.DELEGATED_KEY_AUTHORIZATION_MESSAGE_HASH
        )
      );
  }

  function getIndexPriceHash(IndexPrice memory indexPrice) internal pure returns (bytes32) {
    return
      keccak256(
        abi.encode(
          Constants.EIP_712_TYPE_HASH_INDEX_PRICE,
          keccak256(bytes(indexPrice.baseAssetSymbol)),
          keccak256(bytes(Constants.QUOTE_ASSET_SYMBOL)),
          indexPrice.timestampInMs,
          keccak256(bytes(_pipToDecimal(indexPrice.price)))
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
    // Placing all the fields in a single `abi.encode` call causes a `stack too deep` error
    return
      keccak256(
        abi.encodePacked(
          abi.encode(
            Constants.EIP_712_TYPE_HASH_ORDER,
            order.nonce,
            order.wallet,
            keccak256(abi.encodePacked(baseSymbol, "-", quoteSymbol)),
            uint8(order.orderType),
            uint8(order.side),
            keccak256(bytes(_pipToDecimal(order.quantity))),
            keccak256(bytes(_pipToDecimal(order.limitPrice)))
          ),
          abi.encode(
            keccak256(bytes(_pipToDecimal(order.triggerPrice))),
            uint8(order.triggerType),
            keccak256(bytes(_pipToDecimal(order.callbackRate))),
            order.conditionalOrderId,
            order.isReduceOnly,
            uint8(order.timeInForce),
            uint8(order.selfTradePrevention),
            order.delegatedKeyAuthorization.delegatedPublicKey,
            keccak256(bytes(order.clientOrderId))
          )
        )
      );
  }

  function getTransferHash(Transfer memory transfer) internal pure returns (bytes32) {
    return
      keccak256(
        abi.encode(
          Constants.EIP_712_TYPE_HASH_TRANSFER,
          transfer.nonce,
          transfer.sourceWallet,
          transfer.destinationWallet,
          keccak256(bytes(_pipToDecimal(transfer.grossQuantity)))
        )
      );
  }

  function getWithdrawalHash(Withdrawal memory withdrawal) internal pure returns (bytes32) {
    return
      keccak256(
        abi.encode(
          Constants.EIP_712_TYPE_HASH_WITHDRAWAL,
          withdrawal.nonce,
          withdrawal.wallet,
          keccak256(bytes(_pipToDecimal(withdrawal.grossQuantity))),
          withdrawal.bridgeAdapter,
          keccak256(withdrawal.bridgeAdapterPayload)
        )
      );
  }

  /**
   * @dev Converts an integer pip quantity back into the fixed-precision decimal pip string
   * originally signed by the wallet. For example, 1234567890 becomes '12.34567890'
   */
  function _pipToDecimal(uint256 pips) private pure returns (string memory) {
    if (pips == 0) {
      return Constants.EMPTY_DECIMAL_STRING;
    }

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
