import { ethers } from 'hardhat';
import { v1 as uuidv1 } from 'uuid';

import { deployAndAssociateContracts } from './helpers';
import { uuidToHexString } from '../lib';

describe('Exchange', function () {
  describe.only('invalidateOrderNonce', async function () {
    it('should work on initial call', async function () {
      const [
        ownerWallet,
        dispatcherWallet,
        exitFundWallet,
        feeWallet,
        insuranceWallet,
        indexPriceCollectionServiceWallet,
        trader1Wallet,
      ] = await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(
        ownerWallet,
        dispatcherWallet,
        exitFundWallet,
        feeWallet,
        insuranceWallet,
        indexPriceCollectionServiceWallet,
      );

      await exchange
        .connect(trader1Wallet)
        .invalidateOrderNonce(uuidToHexString(uuidv1()));
    });

    it('should work on second valid call', async function () {
      const [
        ownerWallet,
        dispatcherWallet,
        exitFundWallet,
        feeWallet,
        insuranceWallet,
        indexPriceCollectionServiceWallet,
        trader1Wallet,
      ] = await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(
        ownerWallet,
        dispatcherWallet,
        exitFundWallet,
        feeWallet,
        insuranceWallet,
        indexPriceCollectionServiceWallet,
      );

      await exchange
        .connect(trader1Wallet)
        .invalidateOrderNonce(uuidToHexString(uuidv1()));

      await exchange
        .connect(trader1Wallet)
        .invalidateOrderNonce(uuidToHexString(uuidv1()));
    });
  });
});
