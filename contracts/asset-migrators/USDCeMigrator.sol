// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAssetMigrator } from "../libraries/Interfaces.sol";

interface INativeConverter {
  // https://github.com/omnifient/usdc-lxly/blob/054dc46/src/NativeConverter.sol
  function convert(address receiver, uint256 amount, bytes calldata permitData) external;

  // https://github.com/omnifient/usdc-lxly/blob/054dc46/src/NativeConverter.sol#L40
  function zkBWUSDC() external returns (address);

  // https://github.com/omnifient/usdc-lxly/blob/054dc46/src/NativeConverter.sol#L37
  function zkUSDCe() external returns (address);
}

contract USDCeMigrator is IAssetMigrator {
  address public custodian;
  address public nativeConverter;

  modifier onlyCustodian() {
    require(msg.sender == custodian, "Caller must be Custodian contract");
    _;
  }

  constructor(address custodian_, address nativeConverter_) {
    require(Address.isContract(custodian_), "Invalid Custodian address");
    require(Address.isContract(nativeConverter_), "Invalid native converter address");

    custodian = custodian_;
    nativeConverter = nativeConverter_;
  }

  /**
   * @notice Migrate an asset quantity to a new address
   *
   * @param sourceAsset The address of the old asset that will be migrated from
   * @param quantityInAssetUnits The quantity of token to transfer in asset units
   */
  function migrate(address sourceAsset, uint256 quantityInAssetUnits) public onlyCustodian {
    require(sourceAsset == INativeConverter(nativeConverter).zkBWUSDC(), "Invalid source asset");

    IERC20(sourceAsset).approve(nativeConverter, quantityInAssetUnits);
    INativeConverter(nativeConverter).convert(custodian, quantityInAssetUnits, "");
  }

  /**
   * @notice Load the address of the destination asset that will be migrated to
   *
   * @return destinationAsset The address of the new asset that will migrated to
   */
  function destinationAsset() external returns (address) {
    return INativeConverter(nativeConverter).zkUSDCe();
  }
}
