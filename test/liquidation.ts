import { ethers } from 'hardhat';

import type { Exchange_v4 } from '../typechain-types';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { decimalToPips, IndexPrice, indexPriceToArgumentStruct } from '../lib';
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

  describe('liquidatePositionBelowMinimum', async function () {
    it('should work for valid wallet position', async function () {
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
            decimalToPips('20000.00000000'),
            [indexPriceToArgumentStruct(indexPrice)],
            [indexPriceToArgumentStruct(indexPrice)],
          )
      ).wait();
    });
  });

  describe('liquidatePositionInDeactivatedMarket', async function () {
    it('should work for valid wallet position and market', async function () {
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
            decimalToPips('20.00000000'),
            trader1Wallet.address,
            decimalToPips('20000.00000000'),
            [indexPriceToArgumentStruct(indexPrice)],
          )
      ).wait();
    });
  });

  describe('liquidateWalletInMaintenance', async function () {
    it('should work for valid wallet', async function () {
      await bootstrapLiquidatedWallet();
    });
  });

  describe('liquidateWalletInMaintenanceDuringSystemRecovery', async function () {
    it('should work for valid wallet', async function () {
      await exchange.connect(trader2Wallet).exitWallet();
      await exchange.withdrawExit(trader2Wallet.address);

      const newIndexPrice = await buildIndexPriceWithValue(
        indexPriceCollectionServiceWallet,
        '2150.00000000',
      );

      await (
        await exchange
          .connect(dispatcherWallet)
          .liquidateWalletInMaintenanceDuringSystemRecovery({
            counterpartyWallet: exitFundWallet.address,
            counterpartyWalletIndexPrices: [],
            liquidatingWallet: trader1Wallet.address,
            liquidatingWalletIndexPrices: [
              indexPriceToArgumentStruct(newIndexPrice),
            ],
            liquidationQuoteQuantities: ['21980.00000000'].map(decimalToPips),
          })
      ).wait();
    });
  });

  describe('liquidateWalletExited', async function () {
    it('should work for valid wallet', async function () {
      await exchange.connect(trader1Wallet).exitWallet();

      await (
        await exchange.connect(dispatcherWallet).liquidateWalletExited({
          counterpartyWallet: insuranceFundWallet.address,
          counterpartyWalletIndexPrices: [
            indexPriceToArgumentStruct(indexPrice),
          ],
          liquidatingWallet: trader1Wallet.address,
          liquidatingWalletIndexPrices: [
            indexPriceToArgumentStruct(indexPrice),
          ],
          liquidationQuoteQuantities: ['20000.00000000'].map(decimalToPips),
        })
      ).wait();
    });
  });
});
