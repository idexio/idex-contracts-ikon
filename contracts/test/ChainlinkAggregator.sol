// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { AggregatorV3Interface as IChainlinkAggregator } from '@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol';

import { Owned } from '../Owned.sol';

contract ChainlinkAggregator is IChainlinkAggregator, Owned {
  int256 public _priceInPips;

  constructor() Owned() {}

  function setPrice(int256 priceInPips) external onlyAdmin {
    require(priceInPips > 0, 'Price cannot be zero');
    require(priceInPips < 2**64, 'Price overflows uint64');
    _priceInPips = priceInPips;
  }

  function decimals() external pure override returns (uint8) {
    return 8;
  }

  function description() external pure returns (string memory) {
    return 'DIL / USDC';
  }

  function getRoundData(uint80 _roundId)
    external
    view
    override
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    )
  {
    return (_roundId, _priceInPips, block.timestamp, block.timestamp, 1);
  }

  function latestRoundData()
    external
    view
    override
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    )
  {
    return (1, int256(_priceInPips), block.timestamp, block.timestamp, 1);
  }

  function version() external pure override returns (uint256) {
    return 4;
  }
}
