// SPDX-License-Identifier: LGPL-3.0-only

import { Constants } from "./Constants.sol";
import { FundingMultiplierQuartet } from "./Structs.sol";
import { Math } from "./Math.sol";

pragma solidity 0.8.17;

library FundingMultiplierQuartetHelper {
  // Avoid magic numbers
  uint64 private constant _QUARTET_SIZE = 4;

  int64 private constant _EMPTY = 2 ** 63 - 1;

  /**
   * @dev Adds a new funding multiplier to an array of quartets
   */
  function publishFundingMultipler(FundingMultiplierQuartet[] storage self, int64 newFundingMultiplier) internal {
    if (self.length > 0) {
      FundingMultiplierQuartet storage fundingMultiplierQuartet = self[self.length - 1];
      if (fundingMultiplierQuartet.fundingMultiplier3 != _EMPTY) {
        // Quartet is fully populated, add new entry
        self.push(FundingMultiplierQuartet(newFundingMultiplier, _EMPTY, _EMPTY, _EMPTY));
      } else if (fundingMultiplierQuartet.fundingMultiplier1 == _EMPTY) {
        fundingMultiplierQuartet.fundingMultiplier1 = newFundingMultiplier;
      } else if (fundingMultiplierQuartet.fundingMultiplier2 == _EMPTY) {
        fundingMultiplierQuartet.fundingMultiplier2 = newFundingMultiplier;
      } else {
        fundingMultiplierQuartet.fundingMultiplier3 = newFundingMultiplier;
      }
    } else {
      // First multiplier for market, add new entry
      self.push(FundingMultiplierQuartet(newFundingMultiplier, _EMPTY, _EMPTY, _EMPTY));
    }
  }

  /**
   * @dev Given a start and end timestamp, scans an array of funding multiplier quartets and calculates the aggreagate
   * funding rate multiplier
   *
   * @param self The array of funding multiplier quartets
   * @param fromTimestampInMs The publish timestamp of the first funding multiplier to apply
   * @param toTimestampInMs The publish timestamp of the last funding multiplier to apply
   * @param lastFundingRatePublishTimestampInMs The publish timestamp of the latest funding multiplier in the array
   */
  function loadAggregateMultiplier(
    FundingMultiplierQuartet[] storage self,
    uint64 fromTimestampInMs,
    uint64 toTimestampInMs,
    uint64 lastFundingRatePublishTimestampInMs
  ) internal view returns (int64) {
    (uint256 startIndex, uint64 startOffset) = _calculateIndexAndOffsetForTimestampInMs(
      self,
      fromTimestampInMs,
      lastFundingRatePublishTimestampInMs
    );
    (uint256 endIndex, uint64 endOffset) = _calculateIndexAndOffsetForTimestampInMs(
      self,
      toTimestampInMs,
      lastFundingRatePublishTimestampInMs
    );

    if (startIndex == endIndex) {
      return _calculateAggregateMultiplierForQuartet(self[startIndex], startOffset, endOffset);
    }

    int64 aggregateMultiplier = _calculateAggregateMultiplierForQuartet(
      self[startIndex],
      startOffset,
      _QUARTET_SIZE - 1
    );
    for (uint256 i = startIndex + 1; i < endIndex; i++) {
      aggregateMultiplier += _calculateAggregateMultiplierForQuartet(self[i], 0, _QUARTET_SIZE - 1);
    }
    aggregateMultiplier += _calculateAggregateMultiplierForQuartet(self[endIndex], 0, endOffset);

    return aggregateMultiplier;
  }

  /**
   * @dev Calculates the aggreagate funding rate multiplier for one quartet
   */
  function _calculateAggregateMultiplierForQuartet(
    FundingMultiplierQuartet memory fundingMultipliers,
    uint256 startOffset,
    uint256 endOffset
  ) private pure returns (int64 aggregateMultiplier) {
    if (startOffset >= 0) {
      aggregateMultiplier += fundingMultipliers.fundingMultiplier0;
    }
    if (startOffset <= 1 && endOffset >= 1) {
      aggregateMultiplier += fundingMultipliers.fundingMultiplier1;
    }
    if (startOffset <= 2 && endOffset >= 2) {
      aggregateMultiplier += fundingMultipliers.fundingMultiplier2;
    }
    if (startOffset <= 3 && endOffset >= 3) {
      aggregateMultiplier += fundingMultipliers.fundingMultiplier3;
    }
  }

  /**
   * @dev Calculates the aggreagate funding rate multiplier for one quartet
   */
  function _countMultipliersInQuartet(
    FundingMultiplierQuartet memory fundingMultipliers
  ) private pure returns (uint64 multiplierCount) {
    if (fundingMultipliers.fundingMultiplier3 != _EMPTY) {
      return 4;
    }
    if (fundingMultipliers.fundingMultiplier2 != _EMPTY) {
      return 3;
    }
    if (fundingMultipliers.fundingMultiplier1 != _EMPTY) {
      return 2;
    }

    return 1;
  }

  function _calculateIndexAndOffsetForTimestampInMs(
    FundingMultiplierQuartet[] storage self,
    uint64 timestampInMs,
    uint64 lastTimestampInMs
  ) private view returns (uint256 index, uint64 offset) {
    uint64 numberOfTrailingMultipliers = (lastTimestampInMs - timestampInMs) / Constants.FUNDING_PERIOD_IN_MS;
    uint64 multipliersInLastQuartet = _countMultipliersInQuartet(self[self.length - 1]);

    if (numberOfTrailingMultipliers <= multipliersInLastQuartet) {
      index = self.length - 1;
      offset = multipliersInLastQuartet - numberOfTrailingMultipliers;
    } else {
      index = self.length - Math.divideRoundUp(numberOfTrailingMultipliers, _QUARTET_SIZE);
      offset = multipliersInLastQuartet - (numberOfTrailingMultipliers % _QUARTET_SIZE);
    }
  }
}
