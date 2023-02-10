// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IExchange, IStargateReceiver } from "./libraries/Interfaces.sol";

contract ExchangeStargateAdapter is IStargateReceiver {
  // Address of Exchange contract
  address public immutable exchange;
  // Address of ERC20 contract used as collateral and quote for all markets
  address public immutable quoteAssetAddress;

  /**
   * @notice Instantiate a new `ExchangeStargateAdapter` contract
   */
  constructor(address exchange_, address quoteAssetAddress_) {
    require(Address.isContract(exchange_), "Invalid Exchange address");
    exchange = exchange_;

    require(Address.isContract(quoteAssetAddress_), "Invalid quote asset address");
    quoteAssetAddress = quoteAssetAddress_;

    IERC20(quoteAssetAddress).approve(exchange, type(uint256).max);
  }

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
  ) external override {
    require(token == address(quoteAssetAddress), "Invalid token");

    address destinationWallet = abi.decode(payload, (address));
    IExchange(exchange).deposit(amountLD, destinationWallet);
  }

  // TODO Add skim function
}
