// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

library Time {
  function getOneDayFromNowInMs() internal view returns (uint64) {
    uint64 secondsInOneDay = 24 * 60 * 60; // 24 hours/day * 60 min/hour * 60 seconds/min
    uint64 msInOneSecond = 1000;

    return (uint64(block.timestamp) + secondsInOneDay) * msInOneSecond;
  }
}
