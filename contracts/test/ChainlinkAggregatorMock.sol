// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { AggregatorV3Interface as IChainlinkAggregator } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import { Owned } from "../Owned.sol";

contract ChainlinkAggregatorMock is IChainlinkAggregator, Owned {
  uint8 public decimals;

  int256 public price;

  constructor() Owned() {
    decimals = 8;
  }

  function setDecimals(uint8 decimals_) external {
    decimals = decimals_;
  }

  function setPrice(int256 newPrice) external {
    price = newPrice;
  }

  function description() external pure returns (string memory) {
    return "DIL / USDC";
  }

  function getRoundData(
    uint80 _roundId
  )
    external
    view
    override
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
  {
    return (_roundId, price, block.timestamp, block.timestamp, 1);
  }

  function latestRoundData()
    external
    view
    override
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
  {
    return (1, int256(price), block.timestamp, block.timestamp, 1);
  }

  function version() external pure override returns (uint256) {
    return 4;
  }
}
