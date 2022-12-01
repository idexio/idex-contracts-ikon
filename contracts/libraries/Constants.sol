// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

/**
 * @dev See GOVERNANCE.md for descriptions of fixed parameters and fees
 */

library Constants {
  bytes public constant ENCODED_DELEGATE_KEY_SIGNATURE_MESSAGE =
    abi.encodePacked(
      "Hello from the IDEX team! Sign this message to prove you have control of this wallet. This won't cost you any gas fees.\n\nMessage:\ndelegated "
    );

  uint64 public constant DEPOSIT_INDEX_NOT_SET = 2 ** 64 - 1;

  string public constant EMPTY_DECIMAL_STRING = "0.00000000";

  // 1 week at 3s/block
  uint256 public constant MAX_CHAIN_PROPAGATION_PERIOD_IN_BLOCKS = (7 * 24 * 60 * 60) / 3;

  // 1 year
  uint256 public constant MAX_DELEGATE_KEY_EXPIRATION_PERIOD_IN_MS = 365 * 24 * 60 * 60 * 1000;

  // 20%
  uint64 public constant MAX_FEE_MULTIPLIER = 20 * 10 ** 6;

  uint64 public constant MS_IN_ONE_HOUR = 1000 * 60 * 60;

  string public constant QUOTE_ASSET_SYMBOL = "USDC";

  uint8 public constant QUOTE_ASSET_DECIMALS = 6;

  uint8 public constant SIGNATURE_HASH_VERSION = 105;

  // To convert integer pips to a fractional price shift decimal left by the pip precision of 8
  // decimals places
  uint64 public constant PIP_PRICE_MULTIPLIER = 10 ** 8;
}
