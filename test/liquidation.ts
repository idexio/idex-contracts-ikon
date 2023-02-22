import { ethers } from 'hardhat';
import { mine } from '@nomicfoundation/hardhat-network-helpers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

import type { Exchange_v4, Governance, USDC } from '../typechain-types';
import { decimalToPips, IndexPrice, indexPriceToArgumentStruct } from '../lib';
import {
  baseAssetSymbol,
  bootstrapLiquidatedWallet,
  buildIndexPrice,
  buildIndexPriceWithValue,
  deployAndAssociateContracts,
  executeTrade,
  expect,
  fundWallets,
} from './helpers';

describe('Exchange', function () {
  let exchange: Exchange_v4;
  let exitFundWallet: SignerWithAddress;
  let governance: Governance;
  let indexPrice: IndexPrice;
  let indexPriceServiceWallet: SignerWithAddress;
  let insuranceFundWallet: SignerWithAddress;
  let ownerWallet: SignerWithAddress;
  let dispatcherWallet: SignerWithAddress;
  let trader1Wallet: SignerWithAddress;
  let trader2Wallet: SignerWithAddress;
  let usdc: USDC;

  beforeEach(async () => {
    const wallets = await ethers.getSigners();

    const [feeWallet] = wallets;
    [
      ,
      dispatcherWallet,
      exitFundWallet,
      indexPriceServiceWallet,
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
      indexPriceServiceWallet,
    );
    exchange = results.exchange;
    governance = results.governance;
    usdc = results.usdc;

    await results.usdc.faucet(dispatcherWallet.address);

    await fundWallets([trader1Wallet, trader2Wallet], exchange, usdc);

    indexPrice = await buildIndexPrice(indexPriceServiceWallet);

    await executeTrade(
      exchange,
      dispatcherWallet,
      indexPrice,
      trader1Wallet,
      trader2Wallet,
    );
  });

  describe('liquidatePositionBelowMinimum', async function () {
    beforeEach(async () => {
      await governance.connect(ownerWallet).initiateMarketOverridesUpgrade(
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
      await mine((1 * 24 * 60 * 60) / 3, { interval: 0 });
      await governance
        .connect(dispatcherWallet)
        .finalizeMarketOverridesUpgrade(baseAssetSymbol, trader1Wallet.address);
    });

    it('should work for valid wallet', async function () {
      await fundWallets([insuranceFundWallet], exchange, usdc);

      await exchange.connect(dispatcherWallet).liquidatePositionBelowMinimum({
        baseAssetSymbol,
        liquidatingWallet: trader1Wallet.address,
        liquidationQuoteQuantity: decimalToPips('20000.00000000'),
      });
    });

    it('should revert when IF cannot acquire', async function () {
      await expect(
        exchange.connect(dispatcherWallet).liquidatePositionBelowMinimum({
          baseAssetSymbol,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/initial margin requirement not met/i);
    });
  });

  describe('liquidatePositionInDeactivatedMarket', async function () {
    it('should work for valid wallet position and market', async function () {
      await (
        await exchange
          .connect(dispatcherWallet)
          .deactivateMarket(baseAssetSymbol)
      ).wait();

      await (
        await exchange
          .connect(dispatcherWallet)
          .liquidatePositionInDeactivatedMarket({
            baseAssetSymbol,
            feeQuantity: decimalToPips('20.00000000'),
            liquidatingWallet: trader1Wallet.address,
            liquidationQuoteQuantity: decimalToPips('20000.00000000'),
          })
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
      const newIndexPrice = await buildIndexPriceWithValue(
        indexPriceServiceWallet,
        '2150.00000000',
        baseAssetSymbol,
        2,
      );

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([indexPriceToArgumentStruct(newIndexPrice)]);

      await exchange.connect(trader2Wallet).exitWallet();
      await exchange.withdrawExit(trader2Wallet.address);

      await (
        await exchange
          .connect(dispatcherWallet)
          .liquidateWalletInMaintenanceDuringSystemRecovery({
            counterpartyWallet: exitFundWallet.address,
            liquidatingWallet: trader1Wallet.address,
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
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantities: ['20000.00000000'].map(decimalToPips),
        })
      ).wait();
    });
  });
});
