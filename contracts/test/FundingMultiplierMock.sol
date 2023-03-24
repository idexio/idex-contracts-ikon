// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { FundingMultiplierQuartet } from "../libraries/Structs.sol";
import { FundingMultiplierQuartetHelper } from "../libraries/FundingMultiplierQuartetHelper.sol";

contract FundingMultiplierMock {
  using FundingMultiplierQuartetHelper for FundingMultiplierQuartet[];

  FundingMultiplierQuartet[] public fundingMultipliers;

  function publishFundingMultiplier(int64 newFundingMultiplier) public {
    fundingMultipliers.publishFundingMultiplier(newFundingMultiplier);
  }

  function loadAggregateMultiplier(
    uint64 fromTimestampInMs,
    uint64 toTimestampInMs,
    uint64 lastFundingRatePublishTimestampInMs
  ) public view returns (int64) {
    return
      fundingMultipliers.loadAggregateMultiplier(
        fromTimestampInMs,
        toTimestampInMs,
        lastFundingRatePublishTimestampInMs
      );
  }
}
