// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Balance, OverridableMarketFields } from "./Structs.sol";

interface IBridgeAdapter {
  function withdrawQuoteAsset(address destinationWallet, uint256 quantity, bytes memory payload) external;
}

/**
 * @notice Interface to Custodian contract. Used by Exchange and Governance contracts for internal
 * calls
 */
interface ICustodian {
  /**
   * @notice Withdraw any asset and amount to a target wallet
   *
   * @dev No balance checking performed
   *
   * @param wallet The wallet to which assets will be returned
   * @param asset The address of the asset to withdraw (ERC-20 contract)
   * @param quantityInAssetUnits The quantity in asset units to withdraw
   */
  function withdraw(address wallet, address asset, uint256 quantityInAssetUnits) external;

  /**
   * @notice Load address of the currently whitelisted Exchange contract
   *
   * @return The address of the currently whitelisted Exchange contract
   */
  function exchange() external view returns (address);

  /**
   * @notice Sets a new Exchange contract address
   *
   * @param newExchange The address of the new whitelisted Exchange contract
   */
  function setExchange(address newExchange) external;

  /**
   * @notice Load address of the currently whitelisted Governance contract
   *
   * @return The address of the currently whitelisted Governance contract
   */
  function governance() external view returns (address);

  /**
   * @notice Sets a new Governance contract address
   *
   * @param newGovernance The address of the new whitelisted Governance contract
   */
  function setGovernance(address newGovernance) external;
}

/**
 * @notice Interface to Exchange contract
 *
 * @dev Used for lazy balance migrations from old to new Exchange after upgrade
 */
interface IExchange {
  /**
   * @notice Load a wallet's balance by asset address, in pips
   *
   * @param wallet The wallet address to load the balance for. Can be different from `msg.sender`
   * @param assetSymbol The asset symbol to load the wallet's balance for
   *
   * @return The quantity denominated in pips of asset at `assetSymbol` currently deposited by `wallet`
   */
  function loadBalanceBySymbol(address wallet, string calldata assetSymbol) external view returns (int64);

  /**
   * @notice Load a wallet's balance-tracking struct by asset symbol
   */
  function loadBalanceStructBySymbol(
    address wallet,
    string calldata assetSymbol
  ) external view returns (Balance memory);

  /**
   * @notice Load the address of the Custodian contract
   *
   * @return The address of the Custodian contract
   */
  function custodian() external view returns (ICustodian);

  /**
   * @notice Deposit quote token
   *
   * @param quantityInAssetUnits The quantity to deposit. The sending wallet must first call the `approve` method on
   * the token contract for at least this quantity
   * @param destinationWallet The wallet which will be credited for the new balance. Defaults to sending wallet if zero
   */

  function deposit(uint256 quantityInAssetUnits, address destinationWallet) external;

  /**
   * @notice Load the number of deposits made to the contract, for use when upgrading to a new
   * Exchange via Governance
   *
   * @return The number of deposits successfully made to the Exchange
   */
  function depositIndex() external view returns (uint64);

  function dispatcherWallet() external view returns (address);

  function setBridgeAdapters(IBridgeAdapter[] memory newBridgeAdapters) external;

  function setIndexPriceServiceWallets(address[] memory newIndexPriceServiceWallets) external;

  function setInsuranceFundWallet(address newInsuranceFundWallet) external;

  function setMarketOverrides(
    string memory baseAssetSymbol,
    OverridableMarketFields memory marketOverrides,
    address wallet
  ) external;
}
