// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { FundingMultiplierQuartet } from "../libraries/Structs.sol";
import { FundingMultiplierQuartetHelper } from "../libraries/FundingMultiplierQuartetHelper.sol";

contract FundingMultiplierMock {
  using FundingMultiplierQuartetHelper for FundingMultiplierQuartet[];

  FundingMultiplierQuartet[] public fundingMultipliers;

  function publishFundingMultiplier(int64 newFundingMultiplier) public {
    fundingMultipliers.publishFundingMultiplier(newFundingMultiplier);
  }

  function loadAggregatePayment(
    uint64 fromTimestampInMs,
    uint64 toTimestampInMs,
    uint64 lastFundingRatePublishTimestampInMs,
    int64 positionSize
  ) public view returns (int64) {
    return
      fundingMultipliers.loadAggregatePayment(
        fromTimestampInMs,
        toTimestampInMs,
        lastFundingRatePublishTimestampInMs,
        positionSize
      );
  }
}
