// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { String } from "../libraries/String.sol";

contract StringMock {
  function startsWith(string memory self, string memory prefix) external pure returns (bool) {
    return String.startsWith(self, prefix);
  }
}
