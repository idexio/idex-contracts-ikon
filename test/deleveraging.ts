import { ethers } from 'hardhat';
import { decimalToPips, IndexPrice, indexPriceToArgumentStruct } from '../lib';

import type { Exchange_v4 } from '../typechain-types';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import {
  baseAssetSymbol,
  bootstrapLiquidatedWallet,
  buildIndexPrice,
  buildIndexPriceWithValue,
  deployAndAssociateContracts,
  executeTrade,
  fundWallets,
} from './helpers';

describe('Exchange', function () {
  let exchange: Exchange_v4;
  let exitFundWallet: SignerWithAddress;
  let indexPrice: IndexPrice;
  let indexPriceCollectionServiceWallet: SignerWithAddress;
  let insuranceFundWallet: SignerWithAddress;
  let ownerWallet: SignerWithAddress;
  let dispatcherWallet: SignerWithAddress;
  let trader1Wallet: SignerWithAddress;
  let trader2Wallet: SignerWithAddress;

  beforeEach(async () => {
    const wallets = await ethers.getSigners();

    const [feeWallet] = wallets;
    [
      ,
      dispatcherWallet,
      exitFundWallet,
      indexPriceCollectionServiceWallet,
      insuranceFundWallet,
      ownerWallet,
      trader1Wallet,
      trader2Wallet,
    ] = wallets;
    const results = await deployAndAssociateContracts(
      ownerWallet,
      dispatcherWallet,
      exitFundWallet,
      feeWallet,
      insuranceFundWallet,
      indexPriceCollectionServiceWallet,
    );
    exchange = results.exchange;

    await results.usdc.faucet(dispatcherWallet.address);

    await fundWallets([trader1Wallet, trader2Wallet], exchange, results.usdc);

    indexPrice = await buildIndexPrice(indexPriceCollectionServiceWallet);

    await executeTrade(
      exchange,
      dispatcherWallet,
      indexPrice,
      trader1Wallet,
      trader2Wallet,
    );
  });

  describe('deleverageInMaintenanceAcquisition', async function () {
    it('should work for valid wallet', async function () {
      const newIndexPrice = await buildIndexPriceWithValue(
        indexPriceCollectionServiceWallet,
        '2150.00000000',
      );

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([indexPriceToArgumentStruct(newIndexPrice)]);

      await (
        await exchange
          .connect(dispatcherWallet)
          .deleverageInMaintenanceAcquisition({
            baseAssetSymbol,
            deleveragingWallet: trader2Wallet.address,
            liquidatingWallet: trader1Wallet.address,
            validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
              '21980.00000000',
            ].map(decimalToPips),
            liquidationBaseQuantity: decimalToPips('10.00000000'),
            liquidationQuoteQuantity: decimalToPips('21980.00000000'),
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
            liquidationQuoteQuantity: decimalToPips('21980.00000000'),
          })
      ).wait();
    });
  });

  describe('deleverageExitAcquisition', async function () {
    it('should work for valid wallet', async function () {
      await exchange.connect(trader2Wallet).exitWallet();

      await (
        await exchange.connect(dispatcherWallet).deleverageExitAcquisition({
          baseAssetSymbol,
          deleveragingWallet: trader1Wallet.address,
          liquidatingWallet: trader2Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '20000.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        })
      ).wait();
    });
  });

  describe('deleverageExitFundClosure', async function () {
    it('should work for open position', async function () {
      await exchange.connect(trader1Wallet).exitWallet();
      await exchange.withdrawExit(trader1Wallet.address);

      await (
        await exchange.connect(dispatcherWallet).deleverageExitFundClosure({
          baseAssetSymbol,
          deleveragingWallet: trader2Wallet.address,
          liquidatingWallet: exitFundWallet.address,
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        })
      ).wait();
    });
  });
});
