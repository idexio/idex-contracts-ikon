// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

/**
 * @notice Mixin that provide separate owner and admin roles for RBAC
 */
abstract contract Owned {
  address _owner;
  address _admin;

  modifier onlyOwner() {
    require(msg.sender == _owner, "Caller must be owner");
    _;
  }
  modifier onlyAdmin() {
    require(msg.sender == _admin, "Caller must be admin");
    _;
  }

  /**
   * @notice Sets both the owner and admin roles to the contract creator
   */
  constructor() {
    _owner = msg.sender;
    _admin = msg.sender;
  }

  /**
   * @notice Sets a new whitelisted admin wallet
   *
   * @param newAdmin The new whitelisted admin wallet. Must be different from the current one
   */
  function setAdmin(address newAdmin) external onlyOwner {
    require(newAdmin != address(0x0), "Invalid wallet address");
    require(newAdmin != _admin, "Must be different from current admin");

    _admin = newAdmin;
  }

  /**
   * @notice Clears the currently whitelisted admin wallet, effectively disabling any functions requiring
   * the admin role
   */
  function removeAdmin() external onlyOwner {
    _admin = address(0x0);
  }

  /**
   * @notice Permanently clears the owner wallet, effectively disabling any functions requiring the owner role
   */
  function removeOwner() external onlyOwner {
    _owner = address(0x0);
  }
}
