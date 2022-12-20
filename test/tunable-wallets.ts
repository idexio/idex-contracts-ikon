import { ethers } from 'hardhat';
import { expect } from 'chai';

import { deployAndAssociateContracts } from './helpers';
import { ethAddress } from '../lib';
import type { Exchange_v4 } from '../typechain-types';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

describe('Exchange', function () {
  let exchange: Exchange_v4;
  let ownerWallet: SignerWithAddress;

  beforeEach(async () => {
    [ownerWallet] = await ethers.getSigners();
    const results = await deployAndAssociateContracts(ownerWallet);
    exchange = results.exchange;
  });

  describe('setExitFundWallet', async function () {
    it('should work for valid wallet', async () => {
      const [, exitFundWallet] = await ethers.getSigners();

      await exchange.setExitFundWallet(exitFundWallet.address);

      expect(await exchange.exitFundWallet()).to.equal(exitFundWallet.address);
    });

    it('should revert for invalid wallet', async () => {
      await expect(
        exchange.setExitFundWallet(ethAddress),
      ).to.eventually.be.rejectedWith(/invalid EF wallet/i);
    });

    it('should revert for wallet already set', async () => {
      await expect(
        exchange.setExitFundWallet(ownerWallet.address),
      ).to.eventually.be.rejectedWith(/must be different/i);
    });
  });

  describe('setFeeWallet', async function () {
    it('should work for valid wallet', async () => {
      const [, feeWallet] = await ethers.getSigners();

      await exchange.setFeeWallet(feeWallet.address);

      expect(await exchange.feeWallet()).to.equal(feeWallet.address);
    });

    it('should revert for invalid wallet', async () => {
      await expect(
        exchange.setFeeWallet(ethAddress),
      ).to.eventually.be.rejectedWith(/invalid fee wallet/i);
    });

    it('should revert for wallet already set', async () => {
      await expect(
        exchange.setFeeWallet(ownerWallet.address),
      ).to.eventually.be.rejectedWith(/must be different/i);
    });
  });

  describe('setInsuranceFundWallet', async function () {
    it('should work for valid wallet', async () => {
      const [ownerWallet, insuranceFundWallet] = await ethers.getSigners();

      await exchange
        .connect(ownerWallet)
        .setInsuranceFundWallet(insuranceFundWallet.address);

      expect(await exchange.insuranceFundWallet()).to.equal(
        insuranceFundWallet.address,
      );
    });

    it('should revert for invalid wallet', async () => {
      await expect(
        exchange.setInsuranceFundWallet(ethAddress),
      ).to.eventually.be.rejectedWith(/invalid IF wallet/i);
    });

    it('should revert for wallet already set', async () => {
      await expect(
        exchange.setInsuranceFundWallet(ownerWallet.address),
      ).to.eventually.be.rejectedWith(/must be different/i);
    });
  });

  describe('setDispatcher', async function () {
    it('should work for valid wallet', async () => {
      const [ownerWallet, dispatcherWallet] = await ethers.getSigners();

      await exchange
        .connect(ownerWallet)
        .setDispatcher(dispatcherWallet.address);

      expect(await exchange.dispatcherWallet()).to.equal(
        dispatcherWallet.address,
      );
    });

    it('should revert for invalid wallet', async () => {
      await expect(
        exchange.setDispatcher(ethAddress),
      ).to.eventually.be.rejectedWith(/invalid wallet/i);
    });

    it('should revert for wallet already set', async () => {
      await expect(
        exchange.setDispatcher(ownerWallet.address),
      ).to.eventually.be.rejectedWith(/must be different/i);
    });
  });
});
