// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { AssetUnitConversions } from "../libraries/AssetUnitConversions.sol";

import { IStargateRouter } from "../bridge-adapters/ExchangeStargateAdapter.sol";

// https://github.com/stargate-protocol/stargate/blob/main/contracts/Pool.sol#L37
struct SwapObj {
  uint256 amount;
  uint256 eqFee;
  uint256 eqReward;
  uint256 lpFee;
  uint256 protocolFee;
  uint256 lkbRemove;
}

// https://github.com/stargate-protocol/stargate/blob/main/contracts/interfaces/IStargateFeeLibrary.sol
interface IStargateFeeLibrary {
  function getFees(
    uint256 _srcPoolId,
    uint256 _dstPoolId,
    uint16 _dstChainId,
    address _from,
    uint256 _amountSD
  ) external view returns (SwapObj memory);
}

// https://github.com/stargate-protocol/stargate/blob/main/contracts/Pool.sol
interface IPool {
  function feeLibrary() external view returns (IStargateFeeLibrary);

  function sharedDecimals() external view returns (uint256);
}

// https://github.com/stargate-protocol/stargate/blob/main/contracts/Factory.sol
interface IStargateFactory {
  function getPool(uint256) external view returns (IPool);
}

interface IStargateRouterExtended is IStargateRouter {
  function factory() external view returns (IStargateFactory);
}

contract StargateFeeAggregator {
  uint256 public immutable poolId;

  // Address of Stargate router contract
  IStargateRouterExtended public immutable router;

  /**
   * @notice Instantiate a new `StargateFeeAggregator` contract
   */
  constructor(uint256 poolId_, address router_) {
    poolId = poolId_;

    require(Address.isContract(router_), "Invalid Stargate Router address");
    router = IStargateRouterExtended(router_);
  }

  /**
   * @notice Load current gas fee for each target chain ID specified in argument array
   *
   * @param chainIds An array of chain IDs
   */
  function loadGasFeesInAssetUnits(
    uint16[] calldata chainIds
  ) public view returns (uint256[] memory gasFeesInAssetUnits) {
    gasFeesInAssetUnits = new uint256[](chainIds.length);

    for (uint256 i = 0; i < chainIds.length; ++i) {
      (gasFeesInAssetUnits[i], ) = router.quoteLayerZeroFee(
        chainIds[i],
        1,
        abi.encodePacked(address(this)),
        "0x",
        IStargateRouter.lzTxObj(0, 0, "0x")
      );
    }
  }

  /**
   * @notice Load net pool fee in pips for specific swap parameters
   */
  function loadPoolFee(
    uint256 sourcePoolId,
    uint256 destinationPoolId,
    uint16 destinationChainId,
    address sourceWallet,
    uint64 quantity
  ) public view returns (uint256 poolFee) {
    IPool pool = router.factory().getPool(poolId);
    uint8 poolDecimals = SafeCast.toUint8(pool.sharedDecimals());

    uint256 quantityInAssetUnits = AssetUnitConversions.pipsToAssetUnits(quantity, poolDecimals);

    SwapObj memory s = pool.feeLibrary().getFees(
      sourcePoolId,
      destinationPoolId,
      destinationChainId,
      sourceWallet,
      quantityInAssetUnits
    );

    return AssetUnitConversions.assetUnitsToPips(s.protocolFee + s.lpFee + s.eqFee - s.eqReward, poolDecimals);
  }
}
