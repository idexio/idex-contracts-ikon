// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IIndexPriceAdapter } from "../libraries/Interfaces.sol";
import { IndexPrice } from "../libraries/Structs.sol";

contract ExchangeIndexPriceAdapterMock {
  IIndexPriceAdapter public indexPriceAdapter;

  constructor(IIndexPriceAdapter indexPriceAdapter_) {
    indexPriceAdapter = indexPriceAdapter_;
  }

  function validateIndexPricePayload(bytes memory payload) public returns (IndexPrice memory) {
    return indexPriceAdapter.validateIndexPricePayload(payload);
  }
}
