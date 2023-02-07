// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { FundingMultiplierQuartet } from "../libraries/Structs.sol";
import { FundingMultiplierQuartetHelper } from "../libraries/FundingMultiplierQuartetHelper.sol";

contract FundingMultipliersMock {
  using FundingMultiplierQuartetHelper for FundingMultiplierQuartet[];

  FundingMultiplierQuartet[] public fundingMultipliers;

  constructor() {}

  function publishFundingMultipler(int64 newFundingMultiplier) external {
    fundingMultipliers.publishFundingMultipler(newFundingMultiplier);
  }

  function loadAggregateMultiplier(
    uint64 fromTimestampInMs,
    uint64 toTimestampInMs,
    uint64 lastFundingRatePublishTimestampInMs
  ) external view returns (int64) {
    return
      fundingMultipliers.loadAggregateMultiplier(
        fromTimestampInMs,
        toTimestampInMs,
        lastFundingRatePublishTimestampInMs
      );
  }
}
