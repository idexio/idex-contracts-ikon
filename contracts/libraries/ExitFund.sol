// SPDX-License-Identifier: LGPL-3.0-only

import { BalanceTracking } from './BalanceTracking.sol';
import { Funding } from './Funding.sol';
import { Margin } from './Margin.sol';
import { FundingMultiplierQuartet, Market, OraclePrice } from './Structs.sol';

pragma solidity 0.8.17;

library ExitFund {
  function getExitFundBalanceOpenedAtBlockNumber(
    address exitFundWallet,
    uint256 currentExitFundBalanceOpenedAtBlockNumber,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet
  ) internal view returns (uint256) {
    bool isExitFundBalanceOpen = baseAssetSymbolsWithOpenPositionsByWallet[
      exitFundWallet
    ].length > 0;

    if (
      currentExitFundBalanceOpenedAtBlockNumber == 0 && isExitFundBalanceOpen
    ) {
      return block.number;
    } else if (
      currentExitFundBalanceOpenedAtBlockNumber > 0 && !isExitFundBalanceOpen
    ) {
      return 0;
    }

    return currentExitFundBalanceOpenedAtBlockNumber;
  }
}
