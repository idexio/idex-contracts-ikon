// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { WalletExit } from "./Structs.sol";

library WalletExits {
  function isWalletExitFinalized(
    address wallet,
    mapping(address => WalletExit) storage walletExits
  ) internal view returns (bool) {
    WalletExit memory exit = walletExits[wallet];
    return exit.exists && exit.effectiveBlockTimestamp <= block.timestamp;
  }
}
