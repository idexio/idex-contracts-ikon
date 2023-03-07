import { ethers } from 'hardhat';
import { mine } from '@nomicfoundation/hardhat-network-helpers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

import type { Exchange_v4, USDC } from '../typechain-types';
import { IndexPrice } from '../lib';
import {
  buildIndexPrice,
  deployAndAssociateContracts,
  executeTrade,
  expect,
  fundWallets,
  quoteAssetDecimals,
} from './helpers';

describe('Exchange', function () {
  let dispatcherWallet: SignerWithAddress;
  let exchange: Exchange_v4;
  let exitFundWallet: SignerWithAddress;
  let indexPrice: IndexPrice;
  let indexPriceServiceWallet: SignerWithAddress;
  let insuranceFundWallet: SignerWithAddress;
  let ownerWallet: SignerWithAddress;
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
      indexPriceServiceWallet,
      insuranceFundWallet,
    );
    exchange = results.exchange;
    usdc = results.usdc;

    await usdc.faucet(dispatcherWallet.address);

    await fundWallets([trader1Wallet, trader2Wallet], exchange, results.usdc);

    indexPrice = await buildIndexPrice(indexPriceServiceWallet);

    await executeTrade(
      exchange,
      dispatcherWallet,
      indexPrice,
      trader1Wallet,
      trader2Wallet,
    );
  });

  describe('exitWallet', function () {
    it('should work for non-exited wallet', async function () {
      await exchange.connect(trader1Wallet).exitWallet();

      const exitEvents = await exchange.queryFilter(
        exchange.filters.WalletExited(),
      );
      expect(exitEvents).to.have.lengthOf(1);
      expect(exitEvents[0].args?.wallet).to.equal(trader1Wallet.address);
    });

    it('should fail for exited wallet', async function () {
      await exchange.connect(trader1Wallet).exitWallet();
      await expect(
        exchange.connect(trader1Wallet).exitWallet(),
      ).to.eventually.be.rejectedWith(/wallet already exited/i);
    });

    it('should fail for EF', async function () {
      await expect(
        exchange.connect(exitFundWallet).exitWallet(),
      ).to.eventually.be.rejectedWith(/cannot exit EF/i);
    });

    it('should fail for IF', async function () {
      await expect(
        exchange.connect(insuranceFundWallet).exitWallet(),
      ).to.eventually.be.rejectedWith(/cannot exit IF/i);
    });
  });

  describe('withdrawExit', function () {
    it('should work for exited wallet', async function () {
      // Deposit additional quote to allow for EF exit withdrawal
      const depositQuantity = ethers.utils.parseUnits(
        '100000.0',
        quoteAssetDecimals,
      );
      await usdc
        .connect(ownerWallet)
        .approve(exchange.address, depositQuantity);
      await (
        await exchange
          .connect(ownerWallet)
          .deposit(depositQuantity, ethers.constants.AddressZero)
      ).wait();

      await exchange.connect(trader1Wallet).exitWallet();
      await exchange.withdrawExit(trader1Wallet.address);
      // Subsequent calls to withdraw exit perform a zero transfer
      await exchange.withdrawExit(trader1Wallet.address);

      await mine(300000, { interval: 0 });

      await exchange.withdrawExit(exitFundWallet.address);
      // Subsequent calls to withdraw exit perform a zero transfer
      await exchange.withdrawExit(exitFundWallet.address);
    });
  });

  describe('clearWalletExit', function () {
    it('should work for exited wallet', async function () {
      await exchange.connect(trader1Wallet).exitWallet();
      await exchange.connect(trader1Wallet).clearWalletExit();

      const exitEvents = await exchange.queryFilter(
        exchange.filters.WalletExitCleared(),
      );
      expect(exitEvents).to.have.lengthOf(1);
      expect(exitEvents[0].args?.wallet).to.equal(trader1Wallet.address);
    });

    it('should revert for walled not exited', async function () {
      await expect(
        exchange.connect(trader1Wallet).clearWalletExit(),
      ).to.eventually.be.rejectedWith(/wallet exit not finalized/i);
    });
  });
});
