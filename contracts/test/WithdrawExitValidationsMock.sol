// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Withdrawing } from "../libraries/Withdrawing.sol";

contract WithdrawExitValidationsMock {
  function validateExitQuoteQuantityAndCoerceIfNeeded(
    bool isExitFundWallet,
    int64 walletQuoteQuantityToWithdraw
  ) public pure returns (int64) {
    return Withdrawing.validateExitQuoteQuantityAndCoerceIfNeeded(isExitFundWallet, walletQuoteQuantityToWithdraw);
  }
}
