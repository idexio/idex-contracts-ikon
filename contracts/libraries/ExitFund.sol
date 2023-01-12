// SPDX-License-Identifier: LGPL-3.0-only

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";

pragma solidity 0.8.17;

library ExitFund {
  using BalanceTracking for BalanceTracking.Storage;

  function getExitFundBalanceOpenedAtBlockNumber(
    address exitFundWallet,
    uint256 currentExitFundBalanceOpenedAtBlockNumber,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet
  ) internal view returns (uint256) {
    bool isPositionOpen = baseAssetSymbolsWithOpenPositionsByWallet[exitFundWallet].length > 0;
    bool isQuoteOpen = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
      exitFundWallet,
      Constants.QUOTE_ASSET_SYMBOL
    ) > 0;

    // Position opened when none was before, return current block number
    if (currentExitFundBalanceOpenedAtBlockNumber == 0 && isPositionOpen) {
      return block.number;
    }

    // Position or quote was open before but both are now closed, reset block number. Note that quote must be
    // drawn down to zero before resetting since EF quote withdrawals are not possible after reset
    if (currentExitFundBalanceOpenedAtBlockNumber > 0 && !(isPositionOpen || isQuoteOpen)) {
      return 0;
    }

    // No change in balance or quote opened block number
    return currentExitFundBalanceOpenedAtBlockNumber;
  }

  function isExitFundPositionOrQuoteOpen(
    address exitFundWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet
  ) internal view returns (bool) {
    return
      baseAssetSymbolsWithOpenPositionsByWallet[exitFundWallet].length > 0 ||
      balanceTracking.loadBalanceFromMigrationSourceIfNeeded(exitFundWallet, Constants.QUOTE_ASSET_SYMBOL) > 0;
  }
}
