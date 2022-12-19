import { ethers } from 'hardhat';
import { expect } from 'chai';

import { deployAndAssociateContracts } from './helpers';
import { ethAddress } from '../lib';

describe('Exchange', function () {
  describe('setExitFundWallet', async function () {
    it('should work for valid wallet', async () => {
      const [ownerWallet, exitFundWallet] = await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(ownerWallet);

      await exchange
        .connect(ownerWallet)
        .setExitFundWallet(exitFundWallet.address);

      expect(await exchange.exitFundWallet()).to.equal(exitFundWallet.address);
    });

    it('should revert for invalid wallet', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(ownerWallet);

      let error;
      try {
        await exchange.connect(ownerWallet).setExitFundWallet(ethAddress);
      } catch (e) {
        error = e;
      }
      expect(error).to.not.be.undefined;
      expect(error)
        .to.have.property('message')
        .to.match(/invalid EF wallet/i);
    });

    it('should revert for wallet already set', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(ownerWallet);

      let error;
      try {
        await exchange
          .connect(ownerWallet)
          .setExitFundWallet(ownerWallet.address);
      } catch (e) {
        error = e;
      }
      expect(error).to.not.be.undefined;
      expect(error)
        .to.have.property('message')
        .to.match(/must be different/i);
    });
  });

  describe('setFeeWallet', async function () {
    it('should work for valid wallet', async () => {
      const [ownerWallet, feeWallet] = await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(ownerWallet);

      await exchange.connect(ownerWallet).setFeeWallet(feeWallet.address);

      expect(await exchange.feeWallet()).to.equal(feeWallet.address);
    });

    it('should revert for invalid wallet', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(ownerWallet);

      let error;
      try {
        await exchange.connect(ownerWallet).setFeeWallet(ethAddress);
      } catch (e) {
        error = e;
      }
      expect(error).to.not.be.undefined;
      expect(error)
        .to.have.property('message')
        .to.match(/invalid fee wallet/i);
    });

    it('should revert for wallet already set', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(ownerWallet);

      let error;
      try {
        await exchange.connect(ownerWallet).setFeeWallet(ownerWallet.address);
      } catch (e) {
        error = e;
      }
      expect(error).to.not.be.undefined;
      expect(error)
        .to.have.property('message')
        .to.match(/must be different/i);
    });
  });

  describe('setInsuranceFundWallet', async function () {
    it('should work for valid wallet', async () => {
      const [ownerWallet, insuranceFundWallet] = await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(ownerWallet);

      await exchange
        .connect(ownerWallet)
        .setInsuranceFundWallet(insuranceFundWallet.address);

      expect(await exchange.insuranceFundWallet()).to.equal(
        insuranceFundWallet.address,
      );
    });

    it('should revert for invalid wallet', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(ownerWallet);

      let error;
      try {
        await exchange.connect(ownerWallet).setInsuranceFundWallet(ethAddress);
      } catch (e) {
        error = e;
      }
      expect(error).to.not.be.undefined;
      expect(error)
        .to.have.property('message')
        .to.match(/invalid IF wallet/i);
    });

    it('should revert for wallet already set', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(ownerWallet);

      let error;
      try {
        await exchange
          .connect(ownerWallet)
          .setInsuranceFundWallet(ownerWallet.address);
      } catch (e) {
        error = e;
      }
      expect(error).to.not.be.undefined;
      expect(error)
        .to.have.property('message')
        .to.match(/must be different/i);
    });
  });

  describe('setDispatcher', async function () {
    it('should work for valid wallet', async () => {
      const [ownerWallet, dispatcherWallet] = await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(ownerWallet);

      await exchange
        .connect(ownerWallet)
        .setDispatcher(dispatcherWallet.address);

      expect(await exchange.dispatcherWallet()).to.equal(
        dispatcherWallet.address,
      );
    });

    it('should revert for invalid wallet', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(ownerWallet);

      let error;
      try {
        await exchange.connect(ownerWallet).setDispatcher(ethAddress);
      } catch (e) {
        error = e;
      }
      expect(error).to.not.be.undefined;
      expect(error)
        .to.have.property('message')
        .to.match(/invalid wallet/i);
    });

    it('should revert for wallet already set', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(ownerWallet);

      let error;
      try {
        await exchange.connect(ownerWallet).setDispatcher(ownerWallet.address);
      } catch (e) {
        error = e;
      }
      expect(error).to.not.be.undefined;
      expect(error)
        .to.have.property('message')
        .to.match(/must be different/i);
    });
  });
});
