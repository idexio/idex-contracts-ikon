// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";

contract StargateV2PoolMock {
  address public quoteTokenAddress;

  constructor(address quoteTokenAddress_) {
    quoteTokenAddress = quoteTokenAddress_;
  }

  function token() external view returns (address) {
    return quoteTokenAddress;
  }

  function lzCompose(
    ILayerZeroComposer composer,
    address _from,
    bytes32 _guid,
    bytes calldata _message,
    address _executor,
    bytes calldata _extraData
  ) public payable {
    composer.lzCompose(_from, _guid, _message, _executor, _extraData);
  }
}
