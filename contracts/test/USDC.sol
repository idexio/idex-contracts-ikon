// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// solhint-disable-next-line contract-name-camelcase
contract USDC is ERC20 {
  uint256 public constant INITIAL_SUPPLY = 10 ** 32;

  uint256 public constant MAX_SUPPLY = 10 ** 35;

  uint256 public constant NUM_TOKENS_RELEASED_BY_FAUCET = 10 ** 9;

  uint256 public fee;

  constructor() ERC20("USD Coin", "USDC") {
    _mint(msg.sender, INITIAL_SUPPLY);
  }

  function decimals() public view virtual override returns (uint8) {
    return 6;
  }

  function faucet(address wallet) public {
    _mint(wallet, NUM_TOKENS_RELEASED_BY_FAUCET);
  }

  function setFee(uint256 fee_) public {
    fee = fee_;
  }

  function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
    _transfer(_msgSender(), recipient, amount - fee);

    return true;
  }

  function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
    _transfer(sender, recipient, amount - fee);

    return true;
  }
}
