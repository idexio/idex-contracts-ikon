import { ethers } from 'hardhat';
import { mine } from '@nomicfoundation/hardhat-network-helpers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { v1 as uuidv1 } from 'uuid';

import type { Exchange_v4, USDC } from '../typechain-types';
import {
  decimalToPips,
  getWithdrawArguments,
  getWithdrawalHash,
  IndexPrice,
  signatureHashVersion,
} from '../lib';
import {
  buildIndexPrice,
  deployAndAssociateContracts,
  executeTrade,
  expect,
  fundWallets,
  quoteAssetDecimals,
} from './helpers';

describe('Exchange', function () {
  describe('withdraw', function () {
    it('should work', async function () {
      const [owner, dispatcher, trader, exitFund, fee, insurance, index] =
        await ethers.getSigners();
      const { exchange, usdc } = await deployAndAssociateContracts(
        owner,
        dispatcher,
        exitFund,
        fee,
        insurance,
        index,
      );

      const depositQuantity = ethers.utils.parseUnits(
        '5.0',
        quoteAssetDecimals,
      );
      await usdc.transfer(trader.address, depositQuantity);
      await usdc.connect(trader).approve(exchange.address, depositQuantity);
      await (await exchange.connect(trader).deposit(depositQuantity)).wait();

      const withdrawal = {
        signatureHashVersion,
        nonce: uuidv1(),
        wallet: trader.address,
        quantity: '1.00000000',
      };
      const signature = await trader.signMessage(
        ethers.utils.arrayify(getWithdrawalHash(withdrawal)),
      );
      await (
        await exchange
          .connect(dispatcher)
          .withdraw(
            ...getWithdrawArguments(withdrawal, '0.00000000', signature),
          )
      ).wait();

      const withdrawnEvents = await exchange.queryFilter(
        exchange.filters.Withdrawn(),
      );
      expect(withdrawnEvents).to.have.lengthOf(1);
      expect(withdrawnEvents[0].args?.quantity).to.equal(
        decimalToPips('1.00000000'),
      );
    });
  });

  describe('withdrawExit', function () {
    let dispatcherWallet: SignerWithAddress;
    let exchange: Exchange_v4;
    let exitFundWallet: SignerWithAddress;
    let indexPrice: IndexPrice;
    let indexPriceCollectionServiceWallet: SignerWithAddress;
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
      usdc = results.usdc;

      await usdc.faucet(dispatcherWallet.address);

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

    it('should work for exited wallet', async function () {
      const depositQuantity = ethers.utils.parseUnits(
        '100000.0',
        quoteAssetDecimals,
      );
      await usdc.approve(exchange.address, depositQuantity);
      await (await exchange.deposit(depositQuantity)).wait();

      await exchange.connect(trader1Wallet).exitWallet();
      await exchange.withdrawExit(trader1Wallet.address);
      // Subsequent calls to withdraw exit perform a zero transfer
      await exchange.withdrawExit(trader1Wallet.address);

      await mine(300000);

      await exchange.withdrawExit(exitFundWallet.address);
      // Subsequent calls to withdraw exit perform a zero transfer
      await exchange.withdrawExit(exitFundWallet.address);
    });
  });
});
