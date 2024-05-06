// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";
import { IOFT, MessagingFee, MessagingReceipt, OFTReceipt, SendParam } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

interface ICustodian {
  function exchange() external view returns (address);
}

interface IExchange {
  function deposit(uint256 quantityInAssetUnits, address destinationWallet) external;
}

/*
 * @notice Mixin that provide separate owner and admin roles for RBAC
 * @dev Copied here from Owned.sol due to Solidity version mismatch
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

// https://github.com/LayerZero-Labs/LayerZero-v2/blob/1fde89479fdc68b1a54cda7f19efa84483fcacc4/oapp/contracts/oft/interfaces/IOFT.sol

interface IStargate is IOFT {

}

contract ExchangeStargateV2Adapter is ILayerZeroComposer, Owned {
  // Address of Custodian contract
  ICustodian public immutable custodian;
  // Must be true or `lzCompose` will revert
  bool public isDepositEnabled;
  // Must be true or `withdrawQuoteAsset` will revert
  bool public isWithdrawEnabled;
  // Address of LayerZero endpoint contract that will call `lzCompose` when triggered by off-chain executor
  address public immutable lzEndpoint;
  // Multiplier in pips used to calculate minimum withdraw quantity after slippage
  uint64 public minimumWithdrawQuantityMultiplier;
  // Address of ERC-20 contract used as collateral and quote for all markets
  IERC20 public immutable quoteAsset;
  // Stargate contract used to send tokens by `withdrawQuoteAsset`
  IStargate public immutable stargate;

  // To convert integer pips to a fractional price shift decimal left by the pip precision of 8
  // decimals places
  uint64 public constant PIP_PRICE_MULTIPLIER = 10 ** 8;

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
    address lzEndpoint_,
    address stargate_,
    address quoteAsset_
  ) Owned() {
    require(Address.isContract(custodian_), "Invalid Custodian address");
    custodian = ICustodian(custodian_);

    minimumWithdrawQuantityMultiplier = minimumWithdrawQuantityMultiplier_;

    require(Address.isContract(stargate_), "Invalid Stargate address");
    stargate = IStargate(stargate_);

    require(Address.isContract(lzEndpoint_), "Invalid LZ Endpoint address");
    lzEndpoint = lzEndpoint_;

    require(Address.isContract(quoteAsset_), "Invalid quote asset address");
    require(stargate.token() == quoteAsset_, "Quote asset address does not match Stargate");
    quoteAsset = IERC20(quoteAsset_);

    IERC20(quoteAsset).approve(custodian.exchange(), type(uint256).max);
    IERC20(quoteAsset).approve(stargate_, type(uint256).max);
  }

  /**
   * @notice Allow incoming native asset to fund contract for gas fees, as well as incoming gas fee refunds
   */
  receive() external payable {}

  /**
   * @notice Composes a LayerZero message from an OApp.
   * @param _from The address initiating the composition, typically the OApp where the lzReceive was called.
   * param _guid The unique identifier for the corresponding LayerZero src/dst tx.
   * @param _message The composed message payload in bytes. NOT necessarily the same payload passed via lzReceive.
   * param _executor The address of the executor for the composed message.
   * param _extraData Additional arbitrary data in bytes passed by the entity who executes the lzCompose.
   */
  function lzCompose(
    address _from,
    bytes32 /* _guid */,
    bytes calldata _message,
    address /* _executor */,
    bytes calldata /* _extraData */
  ) public payable override {
    require(msg.sender == lzEndpoint, "Caller must be LZ Endpoint");
    require(_from == address(stargate), "OApp must be Stargate");
    require(isDepositEnabled, "Deposits disabled");

    // https://github.com/LayerZero-Labs/LayerZero-v2/blob/1fde89479fdc68b1a54cda7f19efa84483fcacc4/oapp/contracts/oft/libs/OFTComposeMsgCodec.sol#L52
    uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);

    // https://github.com/LayerZero-Labs/LayerZero-v2/blob/1fde89479fdc68b1a54cda7f19efa84483fcacc4/oapp/contracts/oft/libs/OFTComposeMsgCodec.sol#L61
    address destinationWallet = abi.decode(OFTComposeMsgCodec.composeMsg(_message), (address));
    require(destinationWallet != address(0x0), "Invalid destination wallet");

    IExchange(custodian.exchange()).deposit(amountLD, destinationWallet);
  }

  /**
   * @notice Allow Admin wallet to withdraw gas fee funding
   */
  function withdrawNativeAsset(address payable destinationContractOrWallet, uint256 quantity) public onlyAdmin {
    (bool success, ) = destinationContractOrWallet.call{ value: quantity }("");
    require(success, "Native asset transfer failed");
  }

  function withdrawQuoteAsset(address destinationWallet, uint256 quantity, bytes memory payload) public onlyExchange {
    require(isWithdrawEnabled, "Withdraw disabled");

    SendParam memory sendParam = _getSendParamForWithdraw(destinationWallet, quantity, payload);

    // https://github.com/LayerZero-Labs/LayerZero-v2/blob/1fde89479fdc68b1a54cda7f19efa84483fcacc4/oapp/contracts/oft/interfaces/IOFT.sol#L127C14-L127C23
    MessagingFee memory messagingFee = stargate.quoteSend(sendParam, false);

    try stargate.send{ value: messagingFee.nativeFee }(sendParam, messagingFee, payable(address(this))) {} catch (
      bytes memory errorData
    ) {
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
   * @notice Estimate actual quantity of quote tokens that will be delivered on target chain after pool fees
   */
  function estimateWithdrawQuantityInAssetUnits(
    address destinationWallet,
    uint64 quantity,
    bytes memory payload
  )
    public
    view
    returns (
      uint256 estimatedWithdrawQuantityInAssetUnits,
      uint256 minimumWithdrawQuantityInAssetUnits,
      uint8 poolDecimals
    )
  {
    uint256 quantityInAssetUnits = _pipsToAssetUnits(quantity, stargate.sharedDecimals());

    SendParam memory sendParam = _getSendParamForWithdraw(destinationWallet, quantityInAssetUnits, payload);

    (, , OFTReceipt memory receipt) = stargate.quoteOFT(sendParam);

    estimatedWithdrawQuantityInAssetUnits = receipt.amountReceivedLD;
    minimumWithdrawQuantityInAssetUnits =
      (quantityInAssetUnits * minimumWithdrawQuantityMultiplier) /
      PIP_PRICE_MULTIPLIER;
    poolDecimals = stargate.sharedDecimals();
  }

  /**
   * @notice Load current gas fee for each target endpoint ID specified in argument array
   *
   * @param layerZeroEndpointIds An array of LZ Endpoint IDs
   */
  function loadGasFeesInAssetUnits(
    uint32[] calldata layerZeroEndpointIds
  ) public view returns (uint256[] memory gasFeesInAssetUnits) {
    gasFeesInAssetUnits = new uint256[](layerZeroEndpointIds.length);

    for (uint256 i = 0; i < layerZeroEndpointIds.length; ++i) {
      SendParam memory sendParam = _getSendParamForWithdraw(
        address(this),
        100000000,
        abi.encode(layerZeroEndpointIds[i])
      );

      MessagingFee memory messagingFee = stargate.quoteSend(sendParam, false);
      gasFeesInAssetUnits[i] = messagingFee.nativeFee;
    }
  }

  function _getSendParamForWithdraw(
    address destinationWallet,
    uint256 quantityInAssetUnits,
    bytes memory payload
  ) private view returns (SendParam memory) {
    uint32 destinationEndpointId = abi.decode(payload, (uint32));

    return
      // https://docs.layerzero.network/v2/developers/evm/oft/quickstart#estimating-gas-fees
      SendParam({
        dstEid: destinationEndpointId,
        to: OFTComposeMsgCodec.addressToBytes32(destinationWallet),
        amountLD: quantityInAssetUnits,
        minAmountLD: (quantityInAssetUnits * minimumWithdrawQuantityMultiplier) / PIP_PRICE_MULTIPLIER,
        extraOptions: bytes(""),
        composeMsg: bytes(""),
        oftCmd: bytes("") // Taxi mode
      });
  }

  /*
   * @dev Copied here from AssetUnitConversions.sol due to Solidity version mismatch
   */
  function _pipsToAssetUnits(uint64 quantity, uint8 assetDecimals) private pure returns (uint256) {
    require(assetDecimals <= 32, "Asset cannot have more than 32 decimals");

    // Exponents cannot be negative, so divide or multiply based on exponent signedness
    if (assetDecimals > 8) {
      return uint256(quantity) * (uint256(10) ** (assetDecimals - 8));
    }
    return uint256(quantity) / (uint256(10) ** (8 - assetDecimals));
  }
}
