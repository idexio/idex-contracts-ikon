// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

library WalletExits {
  struct WalletExit {
    bool exists;
    uint256 effectiveBlockNumber;
  }

  function isWalletExitFinalized(
    address wallet,
    mapping(address => WalletExit) storage walletExits
  ) internal view returns (bool) {
    WalletExit memory exit = walletExits[wallet];
    return exit.exists && exit.effectiveBlockNumber <= block.number;
  }
}
