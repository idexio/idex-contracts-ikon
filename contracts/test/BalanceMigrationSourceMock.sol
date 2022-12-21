// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { Balance } from "../libraries/Structs.sol";

contract BalanceMigrationSourceMock {
  mapping(address => mapping(string => int64)) public balancesInPips;
  uint64 public depositIndex;

  constructor(uint64 depositIndex_) {
    depositIndex = depositIndex_;
  }

  function setBalanceInPipsByAddress(address wallet, string calldata assetSymbol, int64 balanceInPips) external {
    balancesInPips[wallet][assetSymbol] = balanceInPips;
  }

  function loadBalanceBySymbol(address wallet, string calldata assetSymbol) external view returns (int64) {
    return balancesInPips[wallet][assetSymbol];
  }

  function loadBalanceStructBySymbol(
    address wallet,
    string calldata assetSymbol
  ) external view returns (Balance memory) {
    return
      Balance({
        isMigrated: true,
        balance: balancesInPips[wallet][assetSymbol],
        lastUpdateTimestampInMs: 0,
        costBasis: 0
      });
  }
}
