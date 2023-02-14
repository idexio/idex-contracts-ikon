import { ethers } from 'hardhat';
import { expect } from 'chai';
import { mine } from '@nomicfoundation/hardhat-network-helpers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

import { deployAndAssociateContracts } from './helpers';
import type { Exchange_v4 } from '../typechain-types';

describe('Exchange', function () {
  let exchange: Exchange_v4;
  let ownerWallet: SignerWithAddress;

  beforeEach(async () => {
    [ownerWallet] = await ethers.getSigners();
    const results = await deployAndAssociateContracts(ownerWallet);
    exchange = results.exchange;
  });

  describe('initiateInsuranceFundWalletUpgrade', () => {
    let exchange: Exchange_v4;
    let ownerWallet: SignerWithAddress;
    let newInsuranceFundWallet: SignerWithAddress;

    beforeEach(async () => {
      [ownerWallet, newInsuranceFundWallet] = await ethers.getSigners();
      const results = await deployAndAssociateContracts(ownerWallet);
      exchange = results.exchange;
    });

    it('should work for valid wallet address', async () => {
      await exchange.initiateInsuranceFundWalletUpgrade(
        newInsuranceFundWallet.address,
      );
    });

    it('should revert for zero address', async () => {
      await expect(
        exchange.initiateInsuranceFundWalletUpgrade(
          ethers.constants.AddressZero,
        ),
      ).to.eventually.be.rejectedWith(/invalid IF wallet address/i);
    });

    it('should revert for same wallet address', async () => {
      await expect(
        exchange.initiateInsuranceFundWalletUpgrade(ownerWallet.address),
      ).to.eventually.be.rejectedWith(/must be different from current/i);
    });

    it('should revert when upgrade already in progress', async () => {
      await exchange.initiateInsuranceFundWalletUpgrade(
        newInsuranceFundWallet.address,
      );
      await expect(
        exchange.initiateInsuranceFundWalletUpgrade(
          newInsuranceFundWallet.address,
        ),
      ).to.eventually.be.rejectedWith(/upgrade already in progress/i);
    });

    it('should revert when not called by admin', async () => {
      await expect(
        exchange
          .connect((await ethers.getSigners())[1])
          .initiateInsuranceFundWalletUpgrade(newInsuranceFundWallet.address),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });
  });

  describe('cancelInsuranceFundWalletUpgrade', () => {
    let exchange: Exchange_v4;
    let ownerWallet: SignerWithAddress;
    let newInsuranceFundWallet: SignerWithAddress;

    beforeEach(async () => {
      [ownerWallet, newInsuranceFundWallet] = await ethers.getSigners();
      const results = await deployAndAssociateContracts(ownerWallet);
      exchange = results.exchange;
    });

    it('should work when upgrade was initiated', async () => {
      await exchange.initiateInsuranceFundWalletUpgrade(
        newInsuranceFundWallet.address,
      );
      await exchange.cancelInsuranceFundWalletUpgrade();
    });
  });

  describe('finalizeInsuranceFundWalletUpgrade', () => {
    let exchange: Exchange_v4;
    let ownerWallet: SignerWithAddress;
    let newInsuranceFundWallet: SignerWithAddress;

    beforeEach(async () => {
      [ownerWallet, newInsuranceFundWallet] = await ethers.getSigners();
      const results = await deployAndAssociateContracts(ownerWallet);
      exchange = results.exchange;
    });

    it('should work after block delay when upgrade was initiated', async () => {
      await exchange.initiateInsuranceFundWalletUpgrade(
        newInsuranceFundWallet.address,
      );

      await mine((2 * 24 * 60 * 60) / 3, { interval: 0 });

      await exchange.finalizeInsuranceFundWalletUpgrade(
        newInsuranceFundWallet.address,
      );

      await expect(exchange.insuranceFundWallet()).to.eventually.equal(
        newInsuranceFundWallet.address,
      );
    });
  });

  describe('setExitFundWallet', async function () {
    it('should work for valid wallet', async () => {
      const [, exitFundWallet] = await ethers.getSigners();

      await exchange.setExitFundWallet(exitFundWallet.address);

      expect(await exchange.exitFundWallet()).to.equal(exitFundWallet.address);
    });

    it('should revert for invalid wallet', async () => {
      await expect(
        exchange.setExitFundWallet(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/invalid EF wallet/i);
    });

    it('should revert for wallet already set', async () => {
      await expect(
        exchange.setExitFundWallet(ownerWallet.address),
      ).to.eventually.be.rejectedWith(/must be different/i);
    });

    it('should revert when not called by admin', async () => {
      await expect(
        exchange
          .connect((await ethers.getSigners())[1])
          .setExitFundWallet(ownerWallet.address),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
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
        exchange.setFeeWallet(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/invalid fee wallet/i);
    });

    it('should revert for wallet already set', async () => {
      await expect(
        exchange.setFeeWallet(ownerWallet.address),
      ).to.eventually.be.rejectedWith(/must be different/i);
    });

    it('should revert when not called by admin', async () => {
      await expect(
        exchange
          .connect((await ethers.getSigners())[1])
          .setFeeWallet(ownerWallet.address),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
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
        exchange.setDispatcher(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/invalid wallet/i);
    });

    it('should revert for wallet already set', async () => {
      await expect(
        exchange.setDispatcher(ownerWallet.address),
      ).to.eventually.be.rejectedWith(/must be different/i);
    });

    it('should revert when not called by admin', async () => {
      await expect(
        exchange
          .connect((await ethers.getSigners())[1])
          .setDispatcher(ownerWallet.address),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });
  });
});
