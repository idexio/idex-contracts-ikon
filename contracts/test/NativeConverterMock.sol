// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAssetMigrator } from "../libraries/Interfaces.sol";

interface TokenWithMintAndBurn {
  function mint(address account, uint256 amount) external;

  function burn(address account, uint256 amount) external;
}

contract NativeConverterMock {
  address public immutable sourceAsset;
  address public immutable destinationAsset;

  uint256 public mintFee;

  constructor(address sourceAsset_, address destinationAsset_) {
    sourceAsset = sourceAsset_;
    destinationAsset = destinationAsset_;
  }

  function convert(address receiver, uint256 amount, bytes calldata /* permitData */) public returns (address) {
    IERC20(sourceAsset).transferFrom(msg.sender, address(this), amount);

    TokenWithMintAndBurn(sourceAsset).burn(address(this), amount);
    TokenWithMintAndBurn(destinationAsset).mint(receiver, amount - mintFee);

    return destinationAsset;
  }

  function setMintFee(uint256 mintFee_) public {
    mintFee = mintFee_;
  }

  function zkBWUSDC() public view returns (address) {
    return sourceAsset;
  }

  function zkUSDCe() public view returns (address) {
    return destinationAsset;
  }
}
