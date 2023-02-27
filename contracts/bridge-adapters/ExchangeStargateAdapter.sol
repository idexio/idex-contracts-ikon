// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Owned } from "../Owned.sol";
import { IBridgeAdapter, ICustodian, IExchange } from "../libraries/Interfaces.sol";

// https://github.com/stargate-protocol/stargate/blob/main/contracts/interfaces/IStargateReceiver.sol
interface IStargateReceiver {
  /**
   *  @param chainId The remote chainId sending the tokens
   *  @param srcAddress The remote Bridge address
   *  @param nonce The message ordering nonce
   *  @param token The token contract on the local chain
   *  @param amountLD The qty of local _token contract tokens
   *  @param payload ABI-encoded bytes containing additional arguments
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

contract ExchangeStargateAdapter is IBridgeAdapter, IStargateReceiver, Owned {
  // Must be true or `sgReceive` will revert
  bool public isDepositEnabled;
  // Must be true or `withdrawQuoteAsset` will revert
  bool public isWithdrawEnabled;
  // Address of Exchange contract
  ICustodian public immutable custodian;
  // Address of ERC20 contract used as collateral and quote for all markets
  IERC20 public immutable quoteAsset;
  // Address of Stargate router contract
  IStargateRouter public immutable router;

  event WithdrawQuoteAssetFailed(address destinationWallet, uint256 quantity, bytes payload, bytes errorData);

  modifier onlyExchange() {
    require(msg.sender == address(custodian.exchange()), "Caller must be Exchange contract");
    _;
  }

  /**
   * @notice Instantiate a new `ExchangeStargateAdapter` contract
   */
  constructor(address custodian_, address router_, address quoteAsset_) {
    require(Address.isContract(custodian_), "Invalid Custodian address");
    custodian = ICustodian(custodian_);

    require(Address.isContract(router_), "Invalid Router address");
    router = IStargateRouter(router_);

    require(Address.isContract(quoteAsset_), "Invalid quote asset address");
    quoteAsset = IERC20(quoteAsset_);

    IERC20(quoteAsset).approve(custodian.exchange(), type(uint256).max);
    IERC20(quoteAsset).approve(router_, type(uint256).max);
  }

  /**
   * @notice Allow Admin wallet to fund contract with native asset for gas fees
   */
  receive() external payable onlyAdmin {}

  /**
   *  @param token The token contract on the local chain
   *  @param amountLD The qty of local token contract tokens
   *  @param payload The bytes containing the destinationWallet
   */
  function sgReceive(
    uint16 /* chainId */,
    bytes calldata /* srcAddress */,
    uint256 /* nonce */,
    address token,
    uint256 amountLD,
    bytes memory payload
  ) public override {
    require(isDepositEnabled, "Deposits disabled");

    require(token == address(quoteAsset), "Invalid token");

    address destinationWallet = abi.decode(payload, (address));
    IExchange(custodian.exchange()).deposit(amountLD, destinationWallet);
  }

  function withdrawQuoteAsset(address destinationWallet, uint256 quantity, bytes memory payload) public onlyExchange {
    require(isWithdrawEnabled, "Withdraw disabled");

    (uint16 targetChainId, uint16 sourcePoolId, uint256 targetPoolId) = abi.decode(payload, (uint16, uint16, uint256));

    (uint256 fee, ) = router.quoteLayerZeroFee(
      targetChainId,
      1,
      abi.encodePacked(destinationWallet),
      "0x",
      IStargateRouter.lzTxObj(0, 0, abi.encodePacked(destinationWallet))
    );

    try
      // Perform a Stargate swap()
      router.swap{ value: fee }(
        targetChainId,
        sourcePoolId,
        targetPoolId,
        payable(this), // Refund adddress. extra gas (if any) is returned to this address
        quantity,
        0, // TODO Should be user-specified
        IStargateRouter.lzTxObj(0, 0, "0x"), // 0 additional gasLimit increase, 0 airdrop, at 0x address
        abi.encodePacked(msg.sender), // Destination wallet
        bytes("") // No payload, will not perform contract call on target chain
      )
    {} catch (bytes memory errorData) {
      quoteAsset.transfer(destinationWallet, quantity);
      emit WithdrawQuoteAssetFailed(destinationWallet, quantity, payload, errorData);
    }
  }

  function setDepositEnabled(bool isEnabled) public onlyAdmin {
    isDepositEnabled = isEnabled;
  }

  function setWithdrawEnabled(bool isEnabled) public onlyAdmin {
    isWithdrawEnabled = isEnabled;
  }

  /**
   * @notice Sends tokens mistakenly sent directly to the adapter contract to a destination wallet
   */
  function skimToken(address tokenAddress, address destinationWallet) public onlyAdmin {
    require(Address.isContract(tokenAddress), "Invalid token address");

    uint256 balance = IERC20(tokenAddress).balanceOf(address(this));

    // Ignore the return value of transfer
    IERC20(tokenAddress).transfer(destinationWallet, balance);
  }

  /**
   * @notice Allow Admin wallet to withdraw gas fee funding
   */
  function withdrawNativeAsset(address payable destinationWallet, uint256 quantity) public onlyAdmin {
    destinationWallet.transfer(quantity);
  }
}
