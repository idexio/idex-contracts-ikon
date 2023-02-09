// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { AggregatorV3Interface as IChainlinkAggregator } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import { Owned } from "../Owned.sol";

contract ChainlinkAggregatorMock is IChainlinkAggregator, Owned {
  int256 public price;

  constructor() Owned() {}

  function setPrice(int256 newPrice) external onlyAdmin {
    require(newPrice > 0, "Price cannot be zero");
    require(newPrice <= int256(uint256(type(uint64).max)), "Price overflows uint64");
    price = newPrice;
  }

  function decimals() external pure override returns (uint8) {
    return 8;
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
