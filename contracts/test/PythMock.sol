// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { MockPyth } from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

contract PythMock is MockPyth {
  constructor(uint _validTimePeriod, uint _singleUpdateFeeInWei) MockPyth(_validTimePeriod, _singleUpdateFeeInWei) {}
}
