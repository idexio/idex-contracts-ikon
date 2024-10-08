// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { AssetUnitConversions } from "../libraries/AssetUnitConversions.sol";
import { Constants } from "../libraries/Constants.sol";
import { Owned } from "../Owned.sol";
import { IBridgeAdapter, ICustodian, IExchange } from "../libraries/Interfaces.sol";

error InvalidSourcePoolId(uint256 poolId);

// https://github.com/stargate-protocol/stargate/blob/main/contracts/Pool.sol
interface IPool {
  struct SwapObj {
    uint256 amount;
    uint256 eqFee;
    uint256 eqReward;
    uint256 lpFee;
    uint256 protocolFee;
    uint256 lkbRemove;
  }

  function feeLibrary() external view returns (IStargateFeeLibrary);

  function sharedDecimals() external view returns (uint256);

  function token() external view returns (address);
}

// https://github.com/stargate-protocol/stargate/blob/main/contracts/Factory.sol
interface IStargateFactory {
  function getPool(uint256) external view returns (IPool);
}

// https://github.com/stargate-protocol/stargate/blob/main/contracts/interfaces/IStargateFeeLibrary.sol
interface IStargateFeeLibrary {
  function getFees(
    uint256 _srcPoolId,
    uint256 _dstPoolId,
    uint16 _dstChainId,
    address _from,
    uint256 _amountSD
  ) external view returns (IPool.SwapObj memory);
}

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

  function factory() external view returns (IStargateFactory);

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
  struct RouterSwapArguments {
    uint256 fee;
    uint16 _dstChainId;
    uint256 _srcPoolId;
    uint256 _dstPoolId;
    address payable _refundAddress;
    uint256 _amountLD;
    uint256 _minAmountLD;
    IStargateRouter.lzTxObj _lzTxParams;
    bytes _to;
    bytes _payload;
  }

  // Address of Custodian contract
  ICustodian public immutable custodian;
  // Must be true or `sgReceive` will revert
  bool public isDepositEnabled;
  // Must be true or `withdrawQuoteAsset` will revert
  bool public isWithdrawEnabled;
  // Multiplier in pips used to calculate minimum withdraw quantity after slippage
  uint64 public minimumWithdrawQuantityMultiplier;
  // Address of ERC-20 contract used as collateral and quote for all markets
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
  constructor(
    address custodian_,
    uint64 minimumWithdrawQuantityMultiplier_,
    address router_,
    address quoteAsset_
  ) Owned() {
    require(Address.isContract(custodian_), "Invalid Custodian address");
    custodian = ICustodian(custodian_);

    minimumWithdrawQuantityMultiplier = minimumWithdrawQuantityMultiplier_;

    require(Address.isContract(router_), "Invalid Router address");
    router = IStargateRouter(router_);

    require(Address.isContract(quoteAsset_), "Invalid quote asset address");
    quoteAsset = IERC20(quoteAsset_);

    IERC20(quoteAsset).approve(custodian.exchange(), type(uint256).max);
    IERC20(quoteAsset).approve(router_, type(uint256).max);
  }

  /**
   * @notice Allow incoming native asset to fund contract for gas fees, as well as incoming gas fee refunds
   */
  receive() external payable {}

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
    require(msg.sender == address(router), "Caller must be Router");
    require(isDepositEnabled, "Deposits disabled");
    require(token == address(quoteAsset), "Invalid token");

    address destinationWallet = abi.decode(payload, (address));
    require(destinationWallet != address(0x0), "Invalid destination wallet");

    IExchange(custodian.exchange()).deposit(amountLD, destinationWallet);
  }

  function withdrawQuoteAsset(address destinationWallet, uint256 quantity, bytes memory payload) public onlyExchange {
    require(isWithdrawEnabled, "Withdraw disabled");

    (uint16 targetChainId, uint256 sourcePoolId, uint256 targetPoolId) = abi.decode(
      payload,
      (uint16, uint256, uint256)
    );

    (uint256 fee, ) = router.quoteLayerZeroFee(
      targetChainId,
      1,
      abi.encodePacked(destinationWallet),
      "0x",
      IStargateRouter.lzTxObj(0, 0, "0x")
    );

    // Package arguments into struct to avoid stack too deep error
    RouterSwapArguments memory arguments = RouterSwapArguments(
      fee,
      targetChainId,
      sourcePoolId,
      targetPoolId,
      payable(this),
      quantity,
      (quantity * minimumWithdrawQuantityMultiplier) / Constants.PIP_PRICE_MULTIPLIER,
      IStargateRouter.lzTxObj(0, 0, "0x"),
      abi.encodePacked(destinationWallet),
      bytes("")
    );

    try
      // Perform a Stargate swap()
      router.swap{ value: arguments.fee }(
        arguments._dstChainId,
        arguments._srcPoolId,
        arguments._dstPoolId,
        arguments._refundAddress,
        arguments._amountLD,
        arguments._minAmountLD,
        arguments._lzTxParams,
        arguments._to,
        arguments._payload
      )
    {} catch (bytes memory errorData) {
      // If the swap fails, redeposit funds into Exchange so wallet can retry
      IExchange(custodian.exchange()).deposit(quantity, destinationWallet);
      emit WithdrawQuoteAssetFailed(destinationWallet, quantity, payload, errorData);
    }
  }

  function setDepositEnabled(bool isEnabled) public onlyAdmin {
    isDepositEnabled = isEnabled;
  }

  function setMinimumWithdrawQuantityMultiplier(uint64 newMinimumWithdrawQuantityMultiplier) public onlyAdmin {
    minimumWithdrawQuantityMultiplier = newMinimumWithdrawQuantityMultiplier;
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
  function withdrawNativeAsset(address payable destinationContractOrWallet, uint256 quantity) public onlyAdmin {
    (bool success, ) = destinationContractOrWallet.call{ value: quantity }("");
    require(success, "Native asset transfer failed");
  }

  /**
   * @notice Estimate actual quantity of quote tokens that will be delivered on target chain after pool fees
   */
  function estimateWithdrawQuantityInAssetUnitsAfterPoolFees(
    bytes calldata payload,
    uint64 quantity,
    address wallet
  )
    public
    view
    returns (
      uint256 estimatedWithdrawQuantityInAssetUnits,
      uint256 minimumWithdrawQuantityInAssetUnits,
      uint8 poolDecimals
    )
  {
    (, uint256 sourcePoolId, ) = abi.decode(payload, (uint16, uint256, uint256));
    IPool pool = router.factory().getPool(sourcePoolId);
    if (address(pool) == address(0x0) || pool.token() != address(quoteAsset)) {
      revert InvalidSourcePoolId(sourcePoolId);
    }

    poolDecimals = SafeCast.toUint8(pool.sharedDecimals());

    uint256 quantityInAssetUnits = AssetUnitConversions.pipsToAssetUnits(quantity, poolDecimals);
    uint256 netPoolFeesInAssetUnits = _loadNetPoolFeesInAssetUnits(payload, pool, quantityInAssetUnits, wallet);

    estimatedWithdrawQuantityInAssetUnits = quantityInAssetUnits - netPoolFeesInAssetUnits;
    minimumWithdrawQuantityInAssetUnits =
      (quantityInAssetUnits * minimumWithdrawQuantityMultiplier) /
      Constants.PIP_PRICE_MULTIPLIER;
  }

  /**
   * @notice Load current gas fee for each target chain ID specified in argument array
   *
   * @param chainIds An array of chain IDs
   */
  function loadGasFeesInAssetUnits(
    uint16[] calldata chainIds
  ) public view returns (uint256[] memory gasFeesInAssetUnits) {
    gasFeesInAssetUnits = new uint256[](chainIds.length);

    for (uint256 i = 0; i < chainIds.length; ++i) {
      (gasFeesInAssetUnits[i], ) = router.quoteLayerZeroFee(
        chainIds[i],
        1,
        abi.encodePacked(address(this)),
        "0x",
        IStargateRouter.lzTxObj(0, 0, "0x")
      );
    }
  }

  function _loadNetPoolFeesInAssetUnits(
    bytes calldata payload,
    IPool pool,
    uint256 quantityInAssetUnits,
    address wallet
  ) private view returns (uint256) {
    // De-coded redundantly here to avoid stack limitations. Gas usage is not a concern since this is a read-only
    // function
    (uint16 targetChainId, uint256 sourcePoolId, uint256 targetPoolId) = abi.decode(
      payload,
      (uint16, uint256, uint256)
    );

    IPool.SwapObj memory s = pool.feeLibrary().getFees(
      sourcePoolId,
      targetPoolId,
      targetChainId,
      wallet,
      quantityInAssetUnits
    );

    return s.protocolFee + s.lpFee + s.eqFee - s.eqReward;
  }
}
