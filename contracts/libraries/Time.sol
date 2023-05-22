// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

library Time {
  uint64 private constant _SECONDS_IN_ONE_DAY = (24 * 60 * 60); // 24 hours/day * 60 min/hour * 60 seconds/min
  uint64 private constant _MS_IN_ONE_SECOND = 1000;

  function getOneDayFromNowInMs() internal view returns (uint64) {
    return (uint64(block.timestamp) + _SECONDS_IN_ONE_DAY) * _MS_IN_ONE_SECOND;
  }

  // Epoch time starts at midnight UTC, which is the same time of day funding payments should start from
  function getMidnightTodayInMs() internal view returns (uint64) {
    uint64 blockTimestamp = uint64(block.timestamp);
    uint64 midnightTodayInSeconds = blockTimestamp - (blockTimestamp % _SECONDS_IN_ONE_DAY);

    return midnightTodayInSeconds * _MS_IN_ONE_SECOND;
  }

  function getMsSinceMidnight() internal view returns (uint64) {
    uint64 secondsSinceMidnight = uint64(block.timestamp) % _SECONDS_IN_ONE_DAY;

    return secondsSinceMidnight * _MS_IN_ONE_SECOND;
  }
}
