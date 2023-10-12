// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { IStargateRouter } from "../bridge-adapters/ExchangeStargateAdapter.sol";

contract StargateGasFeeAggregator {
  // Address of Stargate router contract
  IStargateRouter public immutable router;

  /**
   * @notice Instantiate a new `StargateGasFeeAggregator` contract
   */
  constructor(address router_) {
    require(Address.isContract(router_), "Invalid Stargate Router address");

    router = IStargateRouter(router_);
  }

  /**
   * @notice Load current gas fee for each target chain ID specified in argument array
   *
   * @param chainIds An array of chain IDs
   */
  function loadGasFees(uint16[] calldata chainIds) public view returns (uint256[] memory gasFees) {
    gasFees = new uint256[](chainIds.length);

    for (uint256 i = 0; i < chainIds.length; ++i) {
      (gasFees[i], ) = router.quoteLayerZeroFee(
        chainIds[i],
        1,
        abi.encodePacked(address(this)),
        "0x",
        IStargateRouter.lzTxObj(0, 0, "0x")
      );
    }
  }
}
