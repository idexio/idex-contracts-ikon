// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.13;

import { IExchange } from './Interfaces.sol';
import { OrderSide } from './Enums.sol';
import { UUID } from './UUID.sol';
import { Order, OrderBookTrade, Withdrawal } from './Structs.sol';

library BalanceTracking {
  struct Balance {
    bool isMigrated;
    int64 balanceInPips;
    // The last funding update timestamp is only relevant for base asset positions
    uint64 lastUpdateTimestampInMs;
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

  // Trading //

  /**
   * @dev Updates buyer, seller, and fee wallet balances for both assets in trade pair according to
   * trade parameters
   */
  function updateForOrderBookTrade(
    Storage storage self,
    Order memory buy,
    Order memory sell,
    OrderBookTrade memory trade,
    address feeWallet
  ) internal {
    Balance storage balance;

    (
      uint64 buyFeeInPips,
      uint64 sellFeeInPips,
      // Use the taker order nonce timestamp as the time of execution
      uint64 executionTimestampInMs
    ) = trade.makerSide == OrderSide.Buy
        ? (
          trade.makerFeeQuantityInPips,
          trade.takerFeeQuantityInPips,
          UUID.getTimestampInMsFromUuidV1(sell.nonce)
        )
        : (
          trade.takerFeeQuantityInPips,
          trade.makerFeeQuantityInPips,
          UUID.getTimestampInMsFromUuidV1(buy.nonce)
        );

    // Seller gives base asset including fees
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      sell.walletAddress,
      trade.baseAssetSymbol
    );
    balance.balanceInPips -= int64(trade.baseQuantityInPips);
    balance.lastUpdateTimestampInMs = executionTimestampInMs;
    // Buyer receives base asset minus fees
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      buy.walletAddress,
      trade.baseAssetSymbol
    );
    balance.balanceInPips += int64(trade.baseQuantityInPips);
    balance.lastUpdateTimestampInMs = executionTimestampInMs;

    // Buyer gives quote asset including fees
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      buy.walletAddress,
      trade.quoteAssetSymbol
    );
    balance.balanceInPips -= int64(trade.quoteQuantityInPips + buyFeeInPips);
    // Seller receives quote asset minus fees
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      sell.walletAddress,
      trade.quoteAssetSymbol
    );
    balance.balanceInPips += int64(trade.quoteQuantityInPips - sellFeeInPips);

    // Maker fee to fee wallet
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      feeWallet,
      trade.quoteAssetSymbol
    );
    balance.balanceInPips += int64(
      trade.makerFeeQuantityInPips + trade.takerFeeQuantityInPips
    );
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
  ) internal returns (Balance storage) {
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
