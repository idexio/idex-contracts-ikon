import { ethers } from 'hardhat';

import { deployAndAssociateContracts, expect } from './helpers';
import {
  Exchange_v4,
  Exchange_v4__factory,
  Governance,
  Governance__factory,
  USDC,
} from '../typechain-types';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

describe('Governance', function () {
  let GovernanceFactory: Governance__factory;

  beforeEach(async () => {
    GovernanceFactory = await ethers.getContractFactory('Governance');
  });

  describe('deploy', async function () {
    it('should work', async () => {
      await GovernanceFactory.deploy(0);
    });
  });

  describe('setAdmin', () => {
    let governance: Governance;

    beforeEach(async () => {
      governance = await GovernanceFactory.deploy(0);
    });

    it('should work for valid wallet', async () => {
      await governance.setAdmin((await ethers.getSigners())[1].address);
    });

    it('should revert for zero address', async () => {
      await expect(
        governance.setAdmin(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/invalid wallet address/i);
    });

    it('should revert for same wallet already set', async () => {
      await governance.setAdmin((await ethers.getSigners())[1].address);

      await expect(
        governance.setAdmin((await ethers.getSigners())[1].address),
      ).to.eventually.be.rejectedWith(/must be different from current admin/i);
    });
  });

  describe('removeAdmin', async function () {
    it('should work', async () => {
      const governance = await GovernanceFactory.deploy(0);
      await governance.removeAdmin();
    });

    it('should revert when not called by owner', async () => {
      const governance = await GovernanceFactory.deploy(0);
      await expect(
        governance.connect((await ethers.getSigners())[1]).removeAdmin(),
      ).to.eventually.be.rejectedWith(/caller must be owner/i);
    });
  });

  describe('removeOwner', async function () {
    it('should work', async () => {
      const governance = await GovernanceFactory.deploy(0);
      await governance.removeOwner();
    });

    it('should revert when not called by owner', async () => {
      const governance = await GovernanceFactory.deploy(0);
      await expect(
        governance.connect((await ethers.getSigners())[1]).removeOwner(),
      ).to.eventually.be.rejectedWith(/caller must be owner/i);
    });
  });

  describe('setCustodian', () => {
    let governance: Governance;

    beforeEach(async () => {
      governance = await GovernanceFactory.deploy(0);
    });

    it('should revert for zero address', async () => {
      await expect(
        governance.setCustodian(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/invalid address/i);
    });

    it('should revert if set more than once', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const { custodian, governance } = await deployAndAssociateContracts(
        ownerWallet,
      );

      await expect(
        governance.setCustodian(custodian.address),
      ).to.eventually.be.rejectedWith(/custodian can only be set once/i);
    });
  });

  describe('initiateExchangeUpgrade', () => {
    let exchange: Exchange_v4;
    let ExchangeFactory: Exchange_v4__factory;
    let governance: Governance;
    let ownerWallet: SignerWithAddress;
    let usdc: USDC;

    beforeEach(async () => {
      [ownerWallet] = await ethers.getSigners();
      const results = await deployAndAssociateContracts(ownerWallet);
      exchange = results.exchange;
      ExchangeFactory = results.ExchangeFactory;
      governance = results.governance;
      usdc = results.usdc;
    });

    it('should work for valid contract address', async () => {
      const newExchange = await ExchangeFactory.deploy(
        ethers.constants.AddressZero,
        usdc.address,
        ownerWallet.address,
        ownerWallet.address,
        ownerWallet.address,
        [ownerWallet.address],
      );

      await governance.initiateExchangeUpgrade(newExchange.address);
    });

    it('should revert for zero contract address', async () => {
      await expect(
        governance.initiateExchangeUpgrade(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/invalid address/i);
    });

    it('should revert for same Exchange address', async () => {
      await expect(
        governance.initiateExchangeUpgrade(exchange.address),
      ).to.eventually.be.rejectedWith(
        /must be different from current exchange/i,
      );
    });

    it('should revert when upgrade already in progress', async () => {
      const newExchange = await ExchangeFactory.deploy(
        ethers.constants.AddressZero,
        usdc.address,
        ownerWallet.address,
        ownerWallet.address,
        ownerWallet.address,
        [ownerWallet.address],
      );

      await governance.initiateExchangeUpgrade(newExchange.address);
      await expect(
        governance.initiateExchangeUpgrade(newExchange.address),
      ).to.eventually.be.rejectedWith(/exchange upgrade already in progress/i);
    });
  });

  describe('cancelExchangeUpgrade', () => {
    let ExchangeFactory: Exchange_v4__factory;
    let governance: Governance;
    let ownerWallet: SignerWithAddress;

    beforeEach(async () => {
      [ownerWallet] = await ethers.getSigners();
      const results = await deployAndAssociateContracts(ownerWallet);
      ExchangeFactory = results.ExchangeFactory;
      governance = results.governance;
    });

    it('should work when upgrade was initiated', async () => {
      const usdc = await (await ethers.getContractFactory('USDC')).deploy();
      const newExchange = await ExchangeFactory.deploy(
        ethers.constants.AddressZero,
        usdc.address,
        ownerWallet.address,
        ownerWallet.address,
        ownerWallet.address,
        [ownerWallet.address],
      );

      await governance.initiateExchangeUpgrade(newExchange.address);
      await governance.cancelExchangeUpgrade();
    });

    it('should revert when no upgrade was initiated', async () => {
      await expect(
        governance.cancelExchangeUpgrade(),
      ).to.eventually.be.rejectedWith(/no exchange upgrade in progress/i);
    });
  });

  describe('finalizeExchangeUpgrade', () => {
    let ExchangeFactory: Exchange_v4__factory;
    let governance: Governance;
    let ownerWallet: SignerWithAddress;
    let usdc: USDC;

    beforeEach(async () => {
      [ownerWallet] = await ethers.getSigners();
      const results = await deployAndAssociateContracts(ownerWallet);
      ExchangeFactory = results.ExchangeFactory;
      governance = results.governance;
      usdc = results.usdc;
    });

    it('should work when upgrade was initiated and addresses match', async () => {
      const newExchange = await ExchangeFactory.deploy(
        ethers.constants.AddressZero,
        usdc.address,
        ownerWallet.address,
        ownerWallet.address,
        ownerWallet.address,
        [ownerWallet.address],
      );

      await governance.initiateExchangeUpgrade(newExchange.address);
      await governance.finalizeExchangeUpgrade(newExchange.address);
    });

    it('should revert when no upgrade was initiated', async () => {
      await expect(
        governance.finalizeExchangeUpgrade(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/no exchange upgrade in progress/i);
    });

    it('should revert when upgrade was initiated and addresses mismatch', async () => {
      const newExchange = await ExchangeFactory.deploy(
        ethers.constants.AddressZero,
        usdc.address,
        ownerWallet.address,
        ownerWallet.address,
        ownerWallet.address,
        [ownerWallet.address],
      );

      await governance.initiateExchangeUpgrade(newExchange.address);
      await expect(
        governance.finalizeExchangeUpgrade(governance.address),
      ).to.eventually.be.rejectedWith(/address mismatch/i);
    });

    it('should revert when block threshold not yet reached', async () => {
      const results = await deployAndAssociateContracts(
        ownerWallet,
        ownerWallet,
        ownerWallet,
        ownerWallet,
        ownerWallet,
        ownerWallet,
        true,
        100,
      );
      governance = results.governance;
      const newExchange = await ExchangeFactory.deploy(
        ethers.constants.AddressZero,
        usdc.address,
        ownerWallet.address,
        ownerWallet.address,
        ownerWallet.address,
        [ownerWallet.address],
      );

      await governance.initiateExchangeUpgrade(newExchange.address);
      await expect(
        governance.finalizeExchangeUpgrade(newExchange.address),
      ).to.eventually.be.rejectedWith(/block threshold not yet reached/i);
    });
  });
});
