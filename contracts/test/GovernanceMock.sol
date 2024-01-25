// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

interface IGovernanceMockCustodian {
  receive() external payable;

  function migrateAsset(address sourceAsset) external returns (address destinationAsset);

  function setAssetMigrator(address assetMigrator) external;

  function setExchange(address exchange) external;

  function setGovernance(address governance) external;
}

contract GovernanceMock {
  IGovernanceMockCustodian _custodian;

  function migrateAsset(address sourceAsset) external {
    _custodian.migrateAsset(sourceAsset);
  }

  function setAssetMigrator(address assetMigrator) external {
    _custodian.setAssetMigrator(assetMigrator);
  }

  function setCustodian(IGovernanceMockCustodian newCustodian) external {
    _custodian = newCustodian;
  }

  function setExchange(address newExchange) external {
    _custodian.setExchange(newExchange);
  }

  function setGovernance(address newGovernance) external {
    _custodian.setGovernance(newGovernance);
  }
}
