// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAssetMigrator, ICustodian } from "./libraries/Interfaces.sol";

/**
 * @notice The Custodian contract. Holds custody of all deposited funds for whitelisted Exchange
 * contract with minimal additional logic
 */
contract Custodian is ICustodian {
  // Events //

  /**
   * @notice Emitted when Governance upgrades the Asset Migrator contract address
   */
  event AssetMigratorChanged(address oldAssetMigrator, address newAssetMigrator);
  /**
   * @notice Emitted on construction and when Governance upgrades the Exchange contract address
   */
  event ExchangeChanged(address oldExchange, address newExchange);
  /**
   * @notice Emitted on construction and when Governance replaces itself by upgrading the Governance contract address
   */
  event GovernanceChanged(address oldGovernance, address newGovernance);

  address public assetMigrator;
  address public exchange;
  address public governance;

  modifier onlyExchange() {
    require(msg.sender == exchange, "Caller must be Exchange contract");
    _;
  }

  modifier onlyGovernance() {
    require(msg.sender == governance, "Caller must be Governance contract");
    _;
  }

  /**
   * @notice Instantiate a new Custodian
   *
   * @dev Sets `owner` and `admin` to `msg.sender`. Sets initial values for Exchange and Governance
   * contract addresses, after which they can only be changed by the currently set Governance contract
   * itself
   *
   * @param exchange_ Address of deployed Exchange contract to whitelist
   * @param governance_ Address of deployed Governance contract to whitelist
   */
  constructor(address exchange_, address governance_) {
    require(Address.isContract(exchange_), "Invalid exchange contract address");
    require(Address.isContract(governance_), "Invalid governance contract address");

    exchange = exchange_;
    governance = governance_;

    emit ExchangeChanged(address(0x0), exchange);
    emit GovernanceChanged(address(0x0), governance);
  }

  /**
   * @notice Migrate the entire balance of an asset to a new address using the currently whitelisted asset migrator
   *
   * @param sourceAsset The address of the asset the Custodian currently holds a balance in
   * @param destinationAsset The address of the new asset that will migrated to
   */
  function migrateAsset(address sourceAsset, address destinationAsset) public onlyExchange {
    require(Address.isContract(sourceAsset), "Invalid source asset address");
    require(Address.isContract(destinationAsset), "Invalid destination asset address");

    uint256 quantityInAssetUnits = IERC20(sourceAsset).balanceOf(address(this));

    require(IERC20(sourceAsset).transfer(assetMigrator, quantityInAssetUnits), "Quote asset transfer failed");
    IAssetMigrator(assetMigrator).migrate(sourceAsset, destinationAsset, quantityInAssetUnits);

    // Entire balance must be migrated
    require(
      IERC20(destinationAsset).balanceOf(address(this)) == quantityInAssetUnits,
      "Balance was not completely migrated"
    );
  }

  /**
   * @notice Withdraw any asset and amount to a target wallet
   *
   * @dev No balance checking performed
   *
   * @param wallet The wallet to which assets will be returned
   * @param asset The address of the asset to withdraw (ERC-20 contract)
   * @param quantityInAssetUnits The quantity in asset units to withdraw
   */
  function withdraw(address wallet, address asset, uint256 quantityInAssetUnits) public override onlyExchange {
    require(IERC20(asset).transfer(wallet, quantityInAssetUnits), "Quote asset transfer failed");
  }

  /**
   * @notice Sets a new asset migrator contract address
   *
   * @param newAssetMigrator The address of the new whitelisted asset migrator contract or zero address to disable migration
   */
  function setAssetMigrator(address newAssetMigrator) public override onlyGovernance {
    require(newAssetMigrator == address(0x0) || Address.isContract(newAssetMigrator), "Invalid contract address");

    address oldAssetMigrator = assetMigrator;
    assetMigrator = newAssetMigrator;

    emit AssetMigratorChanged(oldAssetMigrator, newAssetMigrator);
  }

  /**
   * @notice Sets a new Exchange contract address
   *
   * @param newExchange The address of the new whitelisted Exchange contract
   */
  function setExchange(address newExchange) public override onlyGovernance {
    require(Address.isContract(newExchange), "Invalid contract address");

    address oldExchange = exchange;
    exchange = newExchange;

    emit ExchangeChanged(oldExchange, newExchange);
  }

  /**
   * @notice Sets a new Governance contract address
   *
   * @param newGovernance The address of the new whitelisted Governance contract
   */
  function setGovernance(address newGovernance) public override onlyGovernance {
    require(Address.isContract(newGovernance), "Invalid contract address");

    address oldGovernance = governance;
    governance = newGovernance;

    emit GovernanceChanged(oldGovernance, newGovernance);
  }
}
