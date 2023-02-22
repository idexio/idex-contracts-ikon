// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Owned } from "./Owned.sol";
import { ICrossChainBridgeAdapter, IExchange, IStargateReceiver, IStargateRouter } from "./libraries/Interfaces.sol";

contract ExchangeStargateAdapter is ICrossChainBridgeAdapter, IStargateReceiver, Owned {
  // The pool ID on the source chain
  uint16 public immutable sourcePoolId;
  // The LayerZero ID for the target chain
  uint16 public immutable targetChainId;
  // The pool ID on the target chain
  uint256 public immutable targetPoolId;
  // Address of Exchange contract
  IExchange public immutable exchange;
  // Address of ERC20 contract used as collateral and quote for all markets
  address public immutable quoteAssetAddress;
  // Address of Stargate router contract
  IStargateRouter public immutable router;

  modifier onlyExchange() {
    require(msg.sender == address(exchange), "Caller must be Exchange contract");
    _;
  }

  /**
   * @notice Instantiate a new `ExchangeStargateAdapter` contract
   */
  constructor(
    address exchange_,
    uint16 sourcePoolId_,
    uint16 targetChainId_,
    uint256 targetPoolId_,
    address router_,
    address quoteAssetAddress_
  ) {
    require(Address.isContract(exchange_), "Invalid Exchange address");
    exchange = IExchange(exchange_);

    sourcePoolId = sourcePoolId_;
    targetChainId = targetChainId_;
    targetPoolId = targetPoolId_;

    require(Address.isContract(router_), "Invalid Router address");
    router = IStargateRouter(router_);

    require(Address.isContract(quoteAssetAddress_), "Invalid quote asset address");
    quoteAssetAddress = quoteAssetAddress_;

    IERC20(quoteAssetAddress).approve(address(exchange), type(uint256).max);
  }

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
    require(token == address(quoteAssetAddress), "Invalid token");

    address destinationWallet = abi.decode(payload, (address));
    exchange.deposit(amountLD, destinationWallet);
  }

  function withdrawQuoteAsset(address destinationWallet, uint256 quantity) public onlyExchange {
    (uint256 fee, ) = router.quoteLayerZeroFee(
      targetChainId,
      1,
      abi.encodePacked(destinationWallet),
      "0x",
      IStargateRouter.lzTxObj(0, 0, abi.encodePacked(destinationWallet))
    );

    // perform a Stargate swap() in a solidity smart contract function
    // the msg.value is the "fee" that Stargate needs to pay for the cross chain message
    router.swap{ value: fee }(
      targetChainId, // target chainId (use LayerZero chainId)
      sourcePoolId, // source pool id
      targetPoolId, // dest pool id
      payable(this), // refund adddress. extra gas (if any) is returned to this address
      quantity, // quantity to swap
      0, // the min qty you would accept on the destination
      IStargateRouter.lzTxObj(0, 0, "0x"), // 0 additional gasLimit increase, 0 airdrop, at 0x address
      abi.encodePacked(msg.sender), // the address to send the tokens to on the destination
      bytes("") // bytes param, if you wish to send additional payload you can abi.encode() them here
    );
  }

  function skim(address tokenAddress, address destinationWallet) public onlyAdmin {
    require(Address.isContract(tokenAddress), "Invalid token address");

    uint256 balance = IERC20(tokenAddress).balanceOf(address(this));

    // Ignore the return value of transfer
    IERC20(tokenAddress).transfer(destinationWallet, balance);
  }

  function withdrawNativeAsset(address payable destinationWallet, uint256 quantity) public onlyAdmin {
    destinationWallet.transfer(quantity);
  }
}
