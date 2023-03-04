// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

/**
 * @notice Mixin that provide separate owner and admin roles for RBAC
 */
abstract contract Owned {
  address public ownerWallet;
  address public adminWallet;

  modifier onlyOwner() {
    require(msg.sender == ownerWallet, "Caller must be Owner wallet");
    _;
  }
  modifier onlyAdmin() {
    require(msg.sender == adminWallet, "Caller must be Admin wallet");
    _;
  }

  /**
   * @notice Sets both the owner and admin roles to the contract creator
   */
  constructor() {
    ownerWallet = msg.sender;
    adminWallet = msg.sender;
  }

  /**
   * @notice Sets a new whitelisted admin wallet
   *
   * @param newAdmin The new whitelisted admin wallet. Must be different from the current one
   */
  function setAdmin(address newAdmin) external onlyOwner {
    require(newAdmin != address(0x0), "Invalid wallet address");
    require(newAdmin != adminWallet, "Must be different from current admin");

    adminWallet = newAdmin;
  }

  /**
   * @notice Sets a new owner wallet
   *
   * @param newOwner The new owner wallet. Must be different from the current one
   */
  function setOwner(address newOwner) external onlyOwner {
    require(newOwner != address(0x0), "Invalid wallet address");
    require(newOwner != ownerWallet, "Must be different from current owner");

    ownerWallet = newOwner;
  }

  /**
   * @notice Clears the currently whitelisted admin wallet, effectively disabling any functions requiring
   * the admin role
   */
  function removeAdmin() external onlyOwner {
    adminWallet = address(0x0);
  }

  /**
   * @notice Permanently clears the owner wallet, effectively disabling any functions requiring the owner role
   */
  function removeOwner() external onlyOwner {
    ownerWallet = address(0x0);
  }
}
