// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { AggregatorV3Interface as IChainlinkAggregator } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import { AssetUnitConversions } from "../libraries/AssetUnitConversions.sol";
import { IExchange, IOraclePriceAdapter } from "../libraries/Interfaces.sol";

contract ChainlinkOraclePriceAdapter is IOraclePriceAdapter {
  mapping(string => IChainlinkAggregator) public chainlinkAggregatorsByBaseAssetSymbol;

  /**
   * @notice Instantiate a new `ChainlinkOraclePriceAdapter` contract
   *
   * @param baseAssetSymbols Base asset symbols
   * @param chainlinkAggregators Addresses of Chainlink aggregators corresponding to base asset symbols
   */
  constructor(string[] memory baseAssetSymbols, IChainlinkAggregator[] memory chainlinkAggregators) {
    require(baseAssetSymbols.length == chainlinkAggregators.length, "Argument length mismatch");

    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      require(Address.isContract(address(chainlinkAggregators[i])), "Invalid Chainlink aggregator address");
      chainlinkAggregatorsByBaseAssetSymbol[baseAssetSymbols[i]] = chainlinkAggregators[i];
    }
  }

  /**
   * @notice Return latest price for base asset symbol in quote asset terms. Reverts if no price is available
   */
  function loadPriceForBaseAssetSymbol(string memory baseAssetSymbol) public view returns (uint64 price) {
    IChainlinkAggregator chainlinkAggregator = chainlinkAggregatorsByBaseAssetSymbol[baseAssetSymbol];
    require(address(chainlinkAggregator) != address(0x0), "Missing aggregator for symbol");

    (, int256 answer, , , ) = chainlinkAggregator.latestRoundData();
    require(answer > 0, "Unexpected non-positive feed price");

    price = AssetUnitConversions.assetUnitsToPips(uint256(answer), chainlinkAggregator.decimals());
    require(price > 0, "Unexpected non-positive price");
  }

  /**
   * @notice Sets adapter as active, indicating that it is now whitelisted by the Exchange
   *
   * @dev No-op, this contract has no state to initialize on activation
   */
  function setActive(IExchange) public {}
}
