// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IExchange, IIndexPriceAdapter } from "../libraries/Interfaces.sol";
import { IndexPrice } from "../libraries/Structs.sol";

contract ExchangeIndexPriceAdapterMock {
  event ValidatedIndexPrice(IndexPrice indexPrice);

  IIndexPriceAdapter public indexPriceAdapter;

  constructor(IIndexPriceAdapter indexPriceAdapter_) {
    indexPriceAdapter = indexPriceAdapter_;
  }

  function loadMarketsLength() public pure returns (uint256) {
    return 0;
  }

  function validateIndexPricePayload(bytes memory payload) public {
    emit ValidatedIndexPrice(indexPriceAdapter.validateIndexPricePayload(payload));
  }
}
