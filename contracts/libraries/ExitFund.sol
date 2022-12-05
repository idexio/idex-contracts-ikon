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
    (bool isExitFundPositionOpen, bool isExitFundBalanceOpen) = isExitFundPositionOrBalanceOpen(
      exitFundWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Position opened when none was before, return current block number
    if (currentExitFundBalanceOpenedAtBlockNumber == 0 && isExitFundPositionOpen) {
      return block.number;
    }

    // Position or quote was open before but both are now closed, reset block number
    if (currentExitFundBalanceOpenedAtBlockNumber > 0 && !isExitFundBalanceOpen) {
      return 0;
    }

    // No change in balance or quote opened block number
    return currentExitFundBalanceOpenedAtBlockNumber;
  }

  function isExitFundPositionOrBalanceOpen(
    address exitFundWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet
  ) internal view returns (bool isExitFundPositionOpen, bool isExitFundBalanceOpen) {
    isExitFundPositionOpen = baseAssetSymbolsWithOpenPositionsByWallet[exitFundWallet].length > 0;
    isExitFundBalanceOpen =
      isExitFundPositionOpen ||
      balanceTracking.loadBalanceFromMigrationSourceIfNeeded(exitFundWallet, Constants.QUOTE_ASSET_SYMBOL) > 0;
  }
}
