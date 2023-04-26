// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

/**
 * @dev See GOVERNANCE.md for descriptions of fixed parameters and fees
 */

library Constants {
  uint64 public constant DEPOSIT_INDEX_NOT_SET = type(uint64).max;

  string public constant EIP_712_DOMAIN_NAME = "IDEX";

  string public constant EIP_712_DOMAIN_VERSION = "105";

  string public constant EMPTY_DECIMAL_STRING = "0.00000000";

  bytes32 public constant DELEGATED_KEY_AUTHORIZATION_MESSAGE_HASH =
    keccak256(
      bytes(
        "Hello from the IDEX team! Sign this message to prove you have control of this wallet. This won't cost you any gas fees."
      )
    );

  // 1 hour at 3s/block
  uint256 public constant EXIT_FUND_WITHDRAW_DELAY_IN_BLOCKS = (1 * 60 * 60) / 3;

  // 5 minutes at 3s/block
  uint256 public constant FIELD_UPGRADE_DELAY_IN_BLOCKS = (5 * 60) / 3;

  // 8 hours
  uint64 public constant FUNDING_PERIOD_IN_MS = 8 * 60 * 60 * 1000;

  // 1 week at 3s/block
  uint256 public constant MAX_CHAIN_PROPAGATION_PERIOD_IN_BLOCKS = (7 * 24 * 60 * 60) / 3;

  // 1 year
  uint256 public constant MAX_DELEGATE_KEY_EXPIRATION_PERIOD_IN_MS = 365 * 24 * 60 * 60 * 1000;

  // 20%
  uint64 public constant MAX_FEE_MULTIPLIER = 20 * 10 ** 6;

  // 1 year - value must be evenly divisible by `FUNDING_PERIOD_IN_MS`
  uint64 public constant MAX_FUNDING_TIME_PERIOD_PER_UPDATE_IN_MS = 365 * 24 * 60 * 60 * 1000;

  // Max int64
  uint64 public constant MAX_MAXIMUM_POSITION_SIZE = uint64(type(int64).max);

  // Positions smaller than this threshold will skip quote quantity validation for Position Below Minimum liquidations
  // and skip non-negative total quote validation Wallet Exits
  uint64 public constant MINIMUM_QUOTE_QUANTITY_VALIDATION_THRESHOLD = 10000;

  // To convert integer pips to a fractional price shift decimal left by the pip precision of 8
  // decimals places
  uint64 public constant PIP_PRICE_MULTIPLIER = 10 ** 8;

  string public constant QUOTE_ASSET_SYMBOL = "USD";

  uint8 public constant QUOTE_TOKEN_DECIMALS = 6;

  uint8 public constant SIGNATURE_HASH_VERSION = 105;
}
