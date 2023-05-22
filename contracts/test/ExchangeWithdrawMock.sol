// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

interface ICustodianMock {
  receive() external payable;

  function withdraw(address payable wallet, address asset, uint256 quantityInAssetUnits) external;
}

contract ExchangeWithdrawMock {
  ICustodianMock _custodian;

  function setCustodian(ICustodianMock newCustodian) external {
    _custodian = newCustodian;
  }

  function withdraw(address payable wallet, address asset, uint256 quantityInAssetUnits) external {
    _custodian.withdraw(wallet, asset, quantityInAssetUnits);
  }
}
