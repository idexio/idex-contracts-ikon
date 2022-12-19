// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ICustodian } from "./libraries/Interfaces.sol";
import { Owned } from "./Owned.sol";

/**
 * @notice The Custodian contract. Holds custody of all deposited funds for whitelisted Exchange
 * contract with minimal additional logic
 */
contract Custodian is ICustodian, Owned {
  // Events //

  /**
   * @notice Emitted on construction and when Governance upgrades the Exchange contract address
   */
  event ExchangeChanged(address oldExchange, address newExchange);
  /**
   * @notice Emitted on construction and when Governance replaces itself by upgrading the Governance contract address
   */
  event GovernanceChanged(address oldGovernance, address newGovernance);

  address public exchange;
  address public governance;

  /**
   * @notice Instantiate a new Custodian
   *
   * @dev Sets `owner` and `admin` to `msg.sender`. Sets initial values for Exchange and Governance
   * contract addresses, after which they can only be changed by the currently set Governance contract
   * itself
   *
   * @param exchange_ Address of deployed Exchange contract to whitelist
   * @param governance_ ddress of deployed Governance contract to whitelist
   */
  constructor(address exchange_, address governance_) Owned() {
    require(Address.isContract(exchange_), "Invalid exchange contract address");
    require(Address.isContract(governance_), "Invalid governance contract address");

    exchange = exchange_;
    governance = governance_;

    emit ExchangeChanged(address(0x0), exchange);
    emit GovernanceChanged(address(0x0), governance);
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
  function withdraw(address wallet, address asset, uint256 quantityInAssetUnits) external override onlyExchange {
    IERC20(asset).transfer(wallet, quantityInAssetUnits);
  }

  /**
   * @notice Sets a new Exchange contract address
   *
   * @param newExchange The address of the new whitelisted Exchange contract
   */
  function setExchange(address newExchange) external override onlyGovernance {
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
  function setGovernance(address newGovernance) external override onlyGovernance {
    require(Address.isContract(newGovernance), "Invalid contract address");

    address oldGovernance = governance;
    governance = newGovernance;

    emit GovernanceChanged(oldGovernance, newGovernance);
  }

  // RBAC //

  modifier onlyExchange() {
    require(msg.sender == exchange, "Caller must be Exchange contract");
    _;
  }

  modifier onlyGovernance() {
    require(msg.sender == governance, "Caller must be Governance contract");
    _;
  }
}
