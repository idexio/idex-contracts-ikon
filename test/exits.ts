import { mine } from '@nomicfoundation/hardhat-network-helpers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { ethers, network } from 'hardhat';

import type {
  Exchange_v4,
  USDC,
  WithdrawExitValidationsMock,
} from '../typechain-types';
import { IndexPrice } from '../lib';
import {
  buildIndexPrice,
  deployAndAssociateContracts,
  executeTrade,
  expect,
  fundWallets,
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

  before(async () => {
    await network.provider.send('hardhat_reset');
  });

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
      expect(
        (
          await exchange.loadQuoteQuantityAvailableForExitWithdrawal(
            trader1Wallet.address,
          )
        ).toString(),
      ).to.not.equal('0');

      await exchange.connect(trader1Wallet).exitWallet();
      await exchange.withdrawExit(trader1Wallet.address);

      expect(
        (
          await exchange.loadQuoteQuantityAvailableForExitWithdrawal(
            trader1Wallet.address,
          )
        ).toString(),
      ).to.equal('0');

      expect(
        (
          await exchange.loadQuoteQuantityAvailableForExitWithdrawal(
            trader2Wallet.address,
          )
        ).toString(),
      ).to.not.equal('0');

      await exchange.connect(trader2Wallet).exitWallet();
      await exchange.withdrawExit(trader2Wallet.address);

      expect(
        (
          await exchange.loadQuoteQuantityAvailableForExitWithdrawal(
            trader2Wallet.address,
          )
        ).toString(),
      ).to.equal('0');

      // Subsequent calls to withdraw exit perform a zero transfer
      await exchange.withdrawExit(trader1Wallet.address);
      await exchange.withdrawExit(trader2Wallet.address);
    });

    it('should work for exited wallet', async function () {
      await exchange.connect(trader1Wallet).exitWallet();
      await exchange.withdrawExit(trader1Wallet.address);

      // Expire EF withdraw delay
      await mine(300000, { interval: 0 });

      // Deposit additional quote to allow for EF exit withdrawal
      await fundWallets([ownerWallet], exchange, usdc, '100000.0');

      expect(
        (
          await exchange.loadQuoteQuantityAvailableForExitWithdrawal(
            exitFundWallet.address,
          )
        ).toString(),
      ).to.not.equal('0');

      await exchange.withdrawExit(exitFundWallet.address);

      expect(
        (
          await exchange.loadQuoteQuantityAvailableForExitWithdrawal(
            exitFundWallet.address,
          )
        ).toString(),
      ).to.equal('0');

      // Subsequent calls to withdraw exit perform a zero transfer
      await exchange.withdrawExit(exitFundWallet.address);
    });

    it('should revert for exited wallet before finalized', async function () {
      await exchange.setChainPropagationPeriod(10000);
      await exchange.connect(trader1Wallet).exitWallet();
      await expect(
        exchange.withdrawExit(trader1Wallet.address),
      ).to.eventually.be.rejectedWith(/wallet exit not finalized/i);
    });

    describe('validateExitQuoteQuantityAndCoerceIfNeeded', async function () {
      let withdrawExitValidationsMock: WithdrawExitValidationsMock;

      beforeEach(async () => {
        withdrawExitValidationsMock = await (
          await ethers.getContractFactory('WithdrawExitValidationsMock')
        ).deploy();
      });

      it('should coerce negative values within tolerance', async function () {
        expect(
          (
            await withdrawExitValidationsMock.validateExitQuoteQuantityAndCoerceIfNeeded(
              false,
              -5,
            )
          ).toString(),
        ).to.equal('0');
        expect(
          (
            await withdrawExitValidationsMock.validateExitQuoteQuantityAndCoerceIfNeeded(
              false,
              -9999,
            )
          ).toString(),
        ).to.equal('0');
      });

      it('should not coerce positive values', async function () {
        expect(
          (
            await withdrawExitValidationsMock.validateExitQuoteQuantityAndCoerceIfNeeded(
              false,
              5,
            )
          ).toString(),
        ).to.equal('5');
        expect(
          (
            await withdrawExitValidationsMock.validateExitQuoteQuantityAndCoerceIfNeeded(
              false,
              1000000,
            )
          ).toString(),
        ).to.equal('1000000');
      });

      it('should revert for negative values outside tolerance', async function () {
        await expect(
          withdrawExitValidationsMock.validateExitQuoteQuantityAndCoerceIfNeeded(
            false,
            -1000000,
          ),
        ).to.eventually.be.rejectedWith(/negative quote after exit/i);
      });

      it('should revert for negative values inside tolerance for EF', async function () {
        await expect(
          withdrawExitValidationsMock.validateExitQuoteQuantityAndCoerceIfNeeded(
            true,
            -1,
          ),
        ).to.eventually.be.rejectedWith(/negative quote after exit/i);
      });
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
