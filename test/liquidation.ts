import { ethers } from 'hardhat';
import { decimalToPips, indexPriceToArgumentStruct } from '../lib';
import {
  baseAssetSymbol,
  buildIndexPrice,
  buildIndexPriceWithValue,
  deployAndAssociateContracts,
  executeTrade,
  fundWallets,
} from './helpers';

describe('Liquidation', function () {
  describe('liquidatePositionBelowMinimum', async function () {
    it('should work for valid wallet position', async function () {
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

      await exchange.setMarketOverrides(
        baseAssetSymbol,
        {
          initialMarginFraction: '5000000',
          maintenanceMarginFraction: '3000000',
          incrementalInitialMarginFraction: '1000000',
          baselinePositionSize: '14000000000',
          incrementalPositionSize: '2800000000',
          maximumPositionSize: '282000000000',
          minimumPositionSize: '10000000000',
        },
        trader1Wallet.address,
      );

      await (
        await exchange
          .connect(dispatcherWallet)
          .liquidatePositionBelowMinimum(
            baseAssetSymbol,
            trader1Wallet.address,
            decimalToPips('-20000.00000000'),
            [indexPriceToArgumentStruct(indexPrice)],
            [indexPriceToArgumentStruct(indexPrice)],
          )
      ).wait();
    });
  });

  describe('liquidatePositionInDeactivatedMarket', async function () {
    it('should work for valid wallet position and market', async function () {
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

      await (
        await exchange
          .connect(dispatcherWallet)
          .deactivateMarket(
            baseAssetSymbol,
            indexPriceToArgumentStruct(indexPrice),
          )
      ).wait();

      await (
        await exchange
          .connect(dispatcherWallet)
          .liquidatePositionInDeactivatedMarket(
            baseAssetSymbol,
            trader1Wallet.address,
            decimalToPips('-20000.00000000'),
            [indexPriceToArgumentStruct(indexPrice)],
          )
      ).wait();
    });
  });

  describe('liquidateWalletInMaintenance', async function () {
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
          .liquidateWalletInMaintenance(
            trader1Wallet.address,
            ['-21980.00000000'].map(decimalToPips),
            [indexPriceToArgumentStruct(newIndexPrice)],
            [indexPriceToArgumentStruct(newIndexPrice)],
          )
      ).wait();
    });
  });

  describe('liquidateWalletInMaintenanceDuringSystemRecovery', async function () {
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

      await exchange.connect(trader2Wallet).exitWallet();
      await exchange.withdrawExit(trader2Wallet.address);

      const newIndexPrice = await buildIndexPriceWithValue(
        indexPriceCollectionServiceWallet,
        '2150.00000000',
      );

      await (
        await exchange
          .connect(dispatcherWallet)
          .liquidateWalletInMaintenanceDuringSystemRecovery(
            trader1Wallet.address,
            ['-21980.00000000'].map(decimalToPips),
            [indexPriceToArgumentStruct(newIndexPrice)],
          )
      ).wait();
    });
  });

  describe('liquidateWalletExited', async function () {
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

      await exchange.connect(trader1Wallet).exitWallet();

      await (
        await exchange
          .connect(dispatcherWallet)
          .liquidateWalletExited(
            trader1Wallet.address,
            ['-20000.00000000'].map(decimalToPips),
            [indexPriceToArgumentStruct(indexPrice)],
            [indexPriceToArgumentStruct(indexPrice)],
          )
      ).wait();
    });
  });
});
