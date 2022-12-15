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
          .deleverageInMaintenanceAcquisition({
            baseAssetSymbol,
            deleveragingWallet: trader2Wallet.address,
            liquidatingWallet: trader1Wallet.address,
            liquidationQuoteQuantities: ['-21980.00000000'].map(decimalToPips),
            liquidationBaseQuantity: decimalToPips('10.00000000'),
            liquidationQuoteQuantity: decimalToPips('-21980.00000000'),
            deleveragingWalletIndexPrices: [
              indexPriceToArgumentStruct(newIndexPrice),
            ],
            insuranceFundIndexPrices: [
              indexPriceToArgumentStruct(newIndexPrice),
            ],
            liquidatingWalletIndexPrices: [
              indexPriceToArgumentStruct(newIndexPrice),
            ],
          })
      ).wait();
    });
  });

  describe('deleverageInsuranceFundClosure', async function () {
    it('should work for valid wallet', async function () {
      const {
        dispatcherWallet,
        exchange,
        insuranceWallet,
        liquidationIndexPrice,
        counterpartyWallet,
      } = await bootstrapLiquidatedWallet();

      await (
        await exchange
          .connect(dispatcherWallet)
          .deleverageInsuranceFundClosure({
            baseAssetSymbol,
            deleveragingWallet: counterpartyWallet.address,
            liquidatingWallet: insuranceWallet.address,
            liquidationBaseQuantity: decimalToPips('10.00000000'),
            liquidationQuoteQuantity: decimalToPips('-21980.00000000'),
            liquidatingWalletIndexPrices: [
              indexPriceToArgumentStruct(liquidationIndexPrice),
            ],
            deleveragingWalletIndexPrices: [
              indexPriceToArgumentStruct(liquidationIndexPrice),
            ],
          })
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
        await exchange.connect(dispatcherWallet).deleverageExitAcquisition({
          baseAssetSymbol,
          deleveragingWallet: trader1Wallet.address,
          liquidatingWallet: trader2Wallet.address,
          liquidationQuoteQuantities: ['20000.00000000'].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('-10.00000000'),
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
          deleveragingWalletIndexPrices: [
            indexPriceToArgumentStruct(indexPrice),
          ],
          insuranceFundIndexPrices: [indexPriceToArgumentStruct(indexPrice)],
          liquidatingWalletIndexPrices: [
            indexPriceToArgumentStruct(indexPrice),
          ],
        })
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
        await exchange.connect(dispatcherWallet).deleverageExitFundClosure({
          baseAssetSymbol,
          deleveragingWallet: trader2Wallet.address,
          liquidatingWallet: exitFundWallet.address,
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('-20000.00000000'),
          liquidatingWalletIndexPrices: [
            indexPriceToArgumentStruct(indexPrice),
          ],
          deleveragingWalletIndexPrices: [
            indexPriceToArgumentStruct(indexPrice),
          ],
        })
      ).wait();
    });
  });
});
