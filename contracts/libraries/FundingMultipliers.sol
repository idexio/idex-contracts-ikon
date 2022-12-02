// SPDX-License-Identifier: LGPL-3.0-only

import { Constants } from "./Constants.sol";
import { FundingMultiplierQuartet } from "./Structs.sol";

pragma solidity 0.8.17;

library FundingMultipliers {
  function publishFundingMultipler(FundingMultiplierQuartet[] storage self, int64 newFundingMultiplier) internal {
    if (self.length > 0) {
      FundingMultiplierQuartet storage fundingMultiplierQuartet = self[self.length - 1];
      if (fundingMultiplierQuartet.fundingMultiplier3 != 0) {
        // Quartet is fully populated, add new entry
        self.push(FundingMultiplierQuartet(newFundingMultiplier, 0, 0, 0));
      } else if (fundingMultiplierQuartet.fundingMultiplier1 == 0) {
        fundingMultiplierQuartet.fundingMultiplier1 = newFundingMultiplier;
      } else if (fundingMultiplierQuartet.fundingMultiplier2 == 0) {
        fundingMultiplierQuartet.fundingMultiplier2 = newFundingMultiplier;
      } else {
        fundingMultiplierQuartet.fundingMultiplier3 = newFundingMultiplier;
      }
    } else {
      // First multiplier for market, add new entry
      self.push(FundingMultiplierQuartet(newFundingMultiplier, 0, 0, 0));
    }
  }

  function loadAggregateMultiplier(
    FundingMultiplierQuartet[] storage self,
    uint64 fromTimestampInMs,
    uint64 toTimestampInMs
  ) internal view returns (int64) {
    uint256 numberOfTrailingPeriods = (toTimestampInMs - fromTimestampInMs) / Constants.FUNDING_PERIOD_IN_MS;
    uint256 totalNumberOfEntries = self.length;
    (uint256 startIndex, uint256 startOffset) = numberOfTrailingPeriods > totalNumberOfEntries * 4
      ? (0, 0)
      : (totalNumberOfEntries - (numberOfTrailingPeriods / 4), 4 - (numberOfTrailingPeriods % 4));

    int64 aggregateMultiplier = _calculateAggregateMultiplier(self[startIndex], startOffset);
    for (uint256 index = startIndex + 1; index < totalNumberOfEntries; index++) {
      aggregateMultiplier += _calculateAggregateMultiplier(self[index], 0);
    }

    return aggregateMultiplier;
  }

  function _calculateAggregateMultiplier(
    FundingMultiplierQuartet memory fundingMultipliers,
    uint256 offset
  ) private pure returns (int64) {
    int64 aggregateMultiplier = 0;
    if (offset == 0) {
      aggregateMultiplier += fundingMultipliers.fundingMultiplier0;
    }
    if (offset <= 1) {
      aggregateMultiplier += fundingMultipliers.fundingMultiplier1;
    }
    if (offset <= 2) {
      aggregateMultiplier += fundingMultipliers.fundingMultiplier2;
    }
    if (offset <= 3) {
      aggregateMultiplier += fundingMultipliers.fundingMultiplier3;
    }

    return aggregateMultiplier;
  }
}
