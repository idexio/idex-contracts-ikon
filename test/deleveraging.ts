import { ethers } from 'hardhat';
import { decimalToPips, indexPriceToArgumentStruct } from '../lib';

import {
  baseAssetSymbol,
  bootstrapLiquidatedWallet,
  buildIndexPrice,
  buildIndexPriceWithValue,
  deployAndAssociateContracts,
  executeTrade,
  fundWallets,
  logWalletBalances,
} from './helpers';

describe('Exchange', function () {
  describe('deleverageInMaintenanceAcquisition', async function () {
    it('should work for valid wallet', async function () {
      const [
        ownerWallet,
        dispatcherWallet,
        exitFundWallet,
        feeWallet,
        insuranceWallet,
        indexPriceCollectionServiceWallet,
        trader1Wallet,
        trader2Wallet,
      ] = await ethers.getSigners();
      const { exchange, usdc } = await deployAndAssociateContracts(
        ownerWallet,
        dispatcherWallet,
        exitFundWallet,
        feeWallet,
        insuranceWallet,
        indexPriceCollectionServiceWallet,
      );

      await usdc.connect(dispatcherWallet).faucet(dispatcherWallet.address);

      await fundWallets(
        [trader1Wallet, trader2Wallet, insuranceWallet],
        exchange,
        usdc,
      );

      const indexPrice = await buildIndexPrice(
        indexPriceCollectionServiceWallet,
      );

      await executeTrade(
        exchange,
        dispatcherWallet,
        indexPrice,
        trader1Wallet,
        trader2Wallet,
      );

      const newIndexPrice = await buildIndexPriceWithValue(
        indexPriceCollectionServiceWallet,
        '2150.00000000',
      );

      await (
        await exchange
          .connect(dispatcherWallet)
          .deleverageInMaintenanceAcquisition(
            baseAssetSymbol,
            trader2Wallet.address,
            trader1Wallet.address,
            ['-21980.00000000'].map(decimalToPips),
            decimalToPips('10.00000000'),
            decimalToPips('-21980.00000000'),
            [indexPriceToArgumentStruct(newIndexPrice)],
            [indexPriceToArgumentStruct(newIndexPrice)],
            [indexPriceToArgumentStruct(newIndexPrice)],
          )
      ).wait();
    });
  });

  describe('deleverageInsuranceFundClosure', async function () {
    it('should work for valid wallet', async function () {
      const {
        dispatcherWallet,
        exchange,
        liquidationIndexPrice,
        counterpartyWallet,
      } = await bootstrapLiquidatedWallet();

      await (
        await exchange
          .connect(dispatcherWallet)
          .deleverageInsuranceFundClosure(
            baseAssetSymbol,
            counterpartyWallet.address,
            decimalToPips('10.00000000'),
            decimalToPips('-21980.00000000'),
            [indexPriceToArgumentStruct(liquidationIndexPrice)],
            [indexPriceToArgumentStruct(liquidationIndexPrice)],
          )
      ).wait();
    });
  });

  describe('deleverageExitAcquisition', async function () {
    it('should work for valid wallet', async function () {
      const [
        ownerWallet,
        dispatcherWallet,
        exitFundWallet,
        feeWallet,
        insuranceWallet,
        indexPriceCollectionServiceWallet,
        trader1Wallet,
        trader2Wallet,
      ] = await ethers.getSigners();
      const { exchange, usdc } = await deployAndAssociateContracts(
        ownerWallet,
        dispatcherWallet,
        exitFundWallet,
        feeWallet,
        insuranceWallet,
        indexPriceCollectionServiceWallet,
      );

      await usdc.connect(dispatcherWallet).faucet(dispatcherWallet.address);

      await fundWallets([trader1Wallet, trader2Wallet], exchange, usdc);

      const indexPrice = await buildIndexPrice(
        indexPriceCollectionServiceWallet,
      );

      await executeTrade(
        exchange,
        dispatcherWallet,
        indexPrice,
        trader1Wallet,
        trader2Wallet,
      );

      await exchange.connect(trader2Wallet).exitWallet();

      await (
        await exchange
          .connect(dispatcherWallet)
          .deleverageExitAcquisition(
            baseAssetSymbol,
            trader1Wallet.address,
            trader2Wallet.address,
            ['20000.00000000'].map(decimalToPips),
            decimalToPips('-10.00000000'),
            decimalToPips('20000.00000000'),
            [indexPriceToArgumentStruct(indexPrice)],
            [indexPriceToArgumentStruct(indexPrice)],
            [indexPriceToArgumentStruct(indexPrice)],
          )
      ).wait();
    });
  });

  describe('deleverageExitFundClosure', async function () {
    it('should work for open position', async function () {
      const [
        ownerWallet,
        dispatcherWallet,
        exitFundWallet,
        feeWallet,
        insuranceWallet,
        indexPriceCollectionServiceWallet,
        trader1Wallet,
        trader2Wallet,
      ] = await ethers.getSigners();
      const { exchange, usdc } = await deployAndAssociateContracts(
        ownerWallet,
        dispatcherWallet,
        exitFundWallet,
        feeWallet,
        insuranceWallet,
        indexPriceCollectionServiceWallet,
      );

      await usdc.connect(dispatcherWallet).faucet(dispatcherWallet.address);

      await fundWallets(
        [trader1Wallet, trader2Wallet, insuranceWallet],
        exchange,
        usdc,
      );

      const indexPrice = await buildIndexPrice(
        indexPriceCollectionServiceWallet,
      );

      await executeTrade(
        exchange,
        dispatcherWallet,
        indexPrice,
        trader1Wallet,
        trader2Wallet,
      );

      await exchange.connect(trader1Wallet).exitWallet();
      await exchange.withdrawExit(trader1Wallet.address);

      await (
        await exchange
          .connect(dispatcherWallet)
          .deleverageExitFundClosure(
            baseAssetSymbol,
            trader2Wallet.address,
            decimalToPips('10.00000000'),
            decimalToPips('-20000.00000000'),
            [indexPriceToArgumentStruct(indexPrice)],
            [indexPriceToArgumentStruct(indexPrice)],
          )
      ).wait();
    });
  });
});
