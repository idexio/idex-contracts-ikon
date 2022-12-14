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
});
