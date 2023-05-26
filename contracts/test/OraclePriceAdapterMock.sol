// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { IExchange, IOraclePriceAdapter } from "../libraries/Interfaces.sol";

contract OraclePriceAdapterMock is IOraclePriceAdapter {
  constructor() {}

  function loadPriceForBaseAssetSymbol(string memory) public pure returns (uint64 price) {
    return 200000000000;
  }

  function setActive(IExchange) public {}
}
