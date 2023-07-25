// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { Constants } from "./Constants.sol";
import { OrderType } from "./Enums.sol";
import { String } from "./String.sol";
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
            keccak256(bytes(String.pipsToDecimalString(order.quantity))),
            keccak256(bytes(String.pipsToDecimalString(order.limitPrice)))
          ),
          abi.encode(
            keccak256(bytes(String.pipsToDecimalString(order.triggerPrice))),
            uint8(order.triggerType),
            keccak256(bytes(String.pipsToDecimalString(order.callbackRate))),
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
          keccak256(bytes(String.pipsToDecimalString(transfer.grossQuantity)))
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
          keccak256(bytes(String.pipsToDecimalString(withdrawal.grossQuantity))),
          withdrawal.bridgeAdapter,
          keccak256(withdrawal.bridgeAdapterPayload)
        )
      );
  }
}
