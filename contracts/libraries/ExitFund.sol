// SPDX-License-Identifier: LGPL-3.0-only

import { BalanceTracking } from './BalanceTracking.sol';
import { Funding } from './Funding.sol';
import { Margin } from './Margin.sol';
import { FundingMultiplierQuartet, Market, OraclePrice } from './Structs.sol';

pragma solidity 0.8.17;

library ExitFund {
  using BalanceTracking for BalanceTracking.Storage;

  function getExitFundBalanceOpenedAtBlockNumber(
    address exitFundWallet,
    uint256 currentExitFundBalanceOpenedAtBlockNumber,
    string memory quoteAssetSymbol,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet
  ) internal view returns (uint256) {
    (
      bool isExitFundPositionOpen,
      bool isExitFundBalanceOpen
    ) = isExitFundPositionOrBalanceOpen(
        exitFundWallet,
        quoteAssetSymbol,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet
      );

    if (
      currentExitFundBalanceOpenedAtBlockNumber == 0 && isExitFundPositionOpen
    ) {
      return block.number;
    } else if (
      currentExitFundBalanceOpenedAtBlockNumber > 0 && !isExitFundBalanceOpen
    ) {
      return 0;
    }

    return currentExitFundBalanceOpenedAtBlockNumber;
  }

  function isExitFundPositionOrBalanceOpen(
    address exitFundWallet,
    string memory quoteAssetSymbol,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet
  )
    internal
    view
    returns (bool isExitFundPositionOpen, bool isExitFundBalanceOpen)
  {
    isExitFundPositionOpen =
      baseAssetSymbolsWithOpenPositionsByWallet[exitFundWallet].length > 0;
    isExitFundBalanceOpen =
      isExitFundPositionOpen ||
      balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
        exitFundWallet,
        quoteAssetSymbol
      ) >
      0;
  }
}
