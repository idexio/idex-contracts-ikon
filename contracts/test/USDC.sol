// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.15;

import { ERC20 } from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract USDC is ERC20 {
  uint256 public INITIAL_SUPPLY = 10**32;

  constructor() ERC20('USD Coin', 'USDC') {
    _mint(msg.sender, INITIAL_SUPPLY);
  }

  function decimals() public view virtual override returns (uint8) {
    return 6;
  }
}
