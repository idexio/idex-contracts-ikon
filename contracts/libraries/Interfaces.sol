// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Balance, CrossChainBridgeAdapter, Market, OverridableMarketFields } from "./Structs.sol";

interface ICrossChainBridgeAdapter {
  function withdrawQuoteAsset(address destinationWallet, uint256 quantity) external;
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

  function setCrossChainBridgeAdapters(CrossChainBridgeAdapter[] memory newCrossChainBridgeAdapters) external;

  function setIndexPriceCollectionServiceWallets(address[] memory newIndexPriceCollectionServiceWallets) external;

  function setInsuranceFundWallet(address newInsuranceFundWallet) external;

  function setMarketOverrides(
    string memory baseAssetSymbol,
    OverridableMarketFields memory marketOverrides,
    address wallet
  ) external;
}

// https://github.com/stargate-protocol/stargate/blob/main/contracts/interfaces/IStargateReceiver.sol
interface IStargateReceiver {
  /**
   *  @param chainId The remote chainId sending the tokens
   *   @param srcAddress The remote Bridge address
   *   @param nonce The message ordering nonce
   *   @param token The token contract on the local chain
   *   @param amountLD The qty of local _token contract tokens
   *   @param payload The bytes containing the _tokenOut, _deadline, _amountOutMin, _toAddr
   */
  function sgReceive(
    uint16 chainId,
    bytes memory srcAddress,
    uint256 nonce,
    address token,
    uint256 amountLD,
    bytes memory payload
  ) external;
}

// https://github.com/stargate-protocol/stargate/blob/main/contracts/interfaces/IStargateRouter.sol
interface IStargateRouter {
  // solhint-disable-next-line contract-name-camelcase
  struct lzTxObj {
    uint256 dstGasForCall;
    uint256 dstNativeAmount;
    bytes dstNativeAddr;
  }

  function swap(
    uint16 _dstChainId,
    uint256 _srcPoolId,
    uint256 _dstPoolId,
    address payable _refundAddress,
    uint256 _amountLD,
    uint256 _minAmountLD,
    lzTxObj memory _lzTxParams,
    bytes calldata _to,
    bytes calldata _payload
  ) external payable;

  function quoteLayerZeroFee(
    uint16 _dstChainId,
    uint8 _functionType,
    bytes calldata _toAddress,
    bytes calldata _transferAndCallPayload,
    lzTxObj memory _lzTxParams
  ) external view returns (uint256, uint256);
}
