// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.13;

import { IExchange } from './Interfaces.sol';
import { Withdrawal } from './Structs.sol';

library BalanceTracking {
  struct Balance {
    bool isMigrated;
    int64 balanceInPips;
    // The updated timestamp is only relevant for base asset positions
    uint64 updatedTimestampInMs;
  }

  struct Storage {
    mapping(address => mapping(string => Balance)) balancesByWalletAssetPair;
    // Predecessor Exchange contract from which to lazily migrate balances
    IExchange migrationSource;
  }

  // Depositing //

  function updateForDeposit(
    Storage storage self,
    address wallet,
    string memory assetSymbol,
    uint64 quantityInPips
  ) internal returns (int64 newBalanceInPips) {
    Balance storage balance = loadBalanceAndMigrateIfNeeded(
      self,
      wallet,
      assetSymbol
    );
    balance.balanceInPips += int64(quantityInPips);

    return balance.balanceInPips;
  }

  // Withdrawing //

  function updateForWithdrawal(
    Storage storage self,
    Withdrawal memory withdrawal,
    string memory assetSymbol,
    address feeWallet
  ) internal returns (int64 newExchangeBalanceInPips) {
    Balance storage balance;

    balance = loadBalanceAndMigrateIfNeeded(
      self,
      withdrawal.walletAddress,
      assetSymbol
    );
    // Reverts if balance is overdrawn
    balance.balanceInPips -= int64(withdrawal.grossQuantityInPips);
    newExchangeBalanceInPips = balance.balanceInPips;

    if (withdrawal.gasFeeInPips > 0) {
      balance = loadBalanceAndMigrateIfNeeded(self, feeWallet, assetSymbol);

      balance.balanceInPips += int64(withdrawal.gasFeeInPips);
    }
  }

  // Accessors //

  function loadBalanceInPipsFromMigrationSourceIfNeeded(
    Storage storage self,
    address wallet,
    string memory assetSymbol
  ) internal view returns (int64) {
    BalanceTracking.Balance memory balance = self.balancesByWalletAssetPair[
      wallet
    ][assetSymbol];

    if (!balance.isMigrated && address(self.migrationSource) != address(0x0)) {
      return
        self.migrationSource.loadBalanceInPipsBySymbol(wallet, assetSymbol);
    }

    return balance.balanceInPips;
  }

  // Lazy updates //

  function loadBalanceAndMigrateIfNeeded(
    Storage storage self,
    address wallet,
    string memory assetSymbol
  ) private returns (Balance storage) {
    Balance storage balance = self.balancesByWalletAssetPair[wallet][
      assetSymbol
    ];

    if (!balance.isMigrated && address(self.migrationSource) != address(0x0)) {
      balance.balanceInPips = self.migrationSource.loadBalanceInPipsBySymbol(
        wallet,
        assetSymbol
      );
      balance.isMigrated = true;
    }

    return balance;
  }
}
