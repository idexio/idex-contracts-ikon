// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IStargateRouter } from "../bridge-adapters/ExchangeStargateAdapter.sol";

contract StargateRouterMock is IStargateRouter {
  uint256 public fee;
  address public quoteTokenAddress;

  constructor(uint256 fee_, address quoteTokenAddress_) {
    quoteTokenAddress = quoteTokenAddress_;
    fee = fee_;
  }

  function swap(
    uint16 /*_dstChainId */,
    uint256 /*_srcPoolId */,
    uint256 /*_dstPoolId */,
    // solhint-disable-next-line no-unused-vars
    address payable /* _refundAddress */,
    uint256 _amountLD,
    uint256 /*_minAmountLD */,
    lzTxObj memory /*_lzTxParams */,
    bytes calldata /*_to */,
    bytes calldata /*_payload */
  ) public payable {
    require(msg.value >= fee, "Stargate: insufficient value");
    IERC20(quoteTokenAddress).transferFrom(msg.sender, address(this), _amountLD);
  }

  function quoteLayerZeroFee(
    uint16 /* dstChainId */,
    uint8 /* _functionType */,
    bytes calldata /* _toAddress */,
    bytes calldata /* _transferAndCallPayload */,
    lzTxObj memory /* _lzTxParams */
  ) public view override returns (uint256, uint256) {
    return (fee, 0);
  }
}
