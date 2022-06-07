// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.13;

import { Constants } from './Constants.sol';
import { IExchange } from './Interfaces.sol';
import { Math } from './Math.sol';
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
    address walletAddress,
    string memory assetSymbol,
    uint64 quantityInPips
  ) internal returns (int64 newBalanceInPips) {
    Balance storage balance = loadBalanceAndMigrateIfNeeded(
      self,
      walletAddress,
      assetSymbol
    );
    balance.balanceInPips += int64(quantityInPips);

    return balance.balanceInPips;
  }

  // Liquidation //

  function updateForLiquidation(
    Storage storage self,
    address walletAddress,
    address insuranceFundWalletAddress,
    string memory baseAssetSymbol,
    string memory collateralAssetSymbol,
    int64 quoteQuantityInPips
  ) internal {
    Balance storage balance;

    // Wallet position goes to zero
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      walletAddress,
      baseAssetSymbol
    );
    int64 positionSizeInPips = balance.balanceInPips;
    balance.balanceInPips = 0;
    // Insurance fund position takes on opposite side
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      insuranceFundWalletAddress,
      baseAssetSymbol
    );
    balance.balanceInPips -= positionSizeInPips;

    // Wallet receives or gives collateral if long or short respectively
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      walletAddress,
      collateralAssetSymbol
    );
    balance.balanceInPips += quoteQuantityInPips;
    // Insurance receives or gives collateral if wallet short or long respectively
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      insuranceFundWalletAddress,
      collateralAssetSymbol
    );
    balance.balanceInPips += quoteQuantityInPips;
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
      int64 buyFeeInPips,
      int64 sellFeeInPips,
      // Use the taker order nonce timestamp as the time of execution
      uint64 executionTimestampInMs
    ) = trade.makerSide == OrderSide.Buy
        ? (
          trade.makerFeeQuantityInPips,
          int64(trade.takerFeeQuantityInPips),
          UUID.getTimestampInMsFromUuidV1(sell.nonce)
        )
        : (
          int64(trade.takerFeeQuantityInPips),
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
    balance.balanceInPips -= int64(trade.quoteQuantityInPips) + buyFeeInPips;
    // Seller receives quote asset minus fees
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      sell.walletAddress,
      trade.quoteAssetSymbol
    );
    balance.balanceInPips += int64(trade.quoteQuantityInPips) - sellFeeInPips;

    // Maker fee to fee wallet
    balance = loadBalanceAndMigrateIfNeeded(
      self,
      feeWallet,
      trade.quoteAssetSymbol
    );
    balance.balanceInPips +=
      trade.makerFeeQuantityInPips +
      int64(trade.takerFeeQuantityInPips);
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
