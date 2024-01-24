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

  // https://github.com/omnifient/usdc-lxly/blob/054dc46/src/NativeConverter.sol#L37C18-L37C25
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

  function migrate(address destinationAsset, uint256 quantityInAssetUnits, address sourceAsset) public onlyCustodian {
    require(destinationAsset == INativeConverter(nativeConverter).zkUSDCe(), "Invalid destination asset");
    require(sourceAsset == INativeConverter(nativeConverter).zkBWUSDC(), "Invalid source asset");

    IERC20(sourceAsset).approve(nativeConverter, quantityInAssetUnits);
    INativeConverter(sourceAsset).convert(custodian, quantityInAssetUnits, "");
  }
}
