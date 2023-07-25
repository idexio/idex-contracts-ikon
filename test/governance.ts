import { ethers, network } from 'hardhat';

import { deployAndAssociateContracts, expect } from './helpers';
import {
  Custodian,
  Exchange_v4,
  Exchange_v4__factory,
  Governance,
  Governance__factory,
  USDC,
} from '../typechain-types';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

describe('Governance', function () {
  before(async () => {
    await network.provider.send('hardhat_reset');
  });

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

    it('should revert when not called by owner', async () => {
      const nonOwnerWallet = (await ethers.getSigners())[1];

      const governance = await GovernanceFactory.deploy(0);
      await expect(
        governance.connect(nonOwnerWallet).setAdmin(nonOwnerWallet.address),
      ).to.eventually.be.rejectedWith(/caller must be owner/i);
    });
  });

  describe('setOwner', () => {
    let governance: Governance;

    beforeEach(async () => {
      governance = await GovernanceFactory.deploy(0);
    });

    it('should work for valid wallet', async () => {
      await governance.setOwner((await ethers.getSigners())[1].address);
    });

    it('should revert for zero address', async () => {
      await expect(
        governance.setOwner(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/invalid wallet address/i);
    });

    it('should revert for same wallet already set', async () => {
      await expect(
        governance.setOwner(await governance.ownerWallet()),
      ).to.eventually.be.rejectedWith(/must be different from current owner/i);
    });

    it('should revert when not called by owner', async () => {
      const nonOwnerWallet = (await ethers.getSigners())[1];

      const governance = await GovernanceFactory.deploy(0);
      await expect(
        governance.connect(nonOwnerWallet).setOwner(nonOwnerWallet.address),
      ).to.eventually.be.rejectedWith(/caller must be owner/i);
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

    it('should revert when not called by admin', async () => {
      await expect(
        governance
          .connect((await ethers.getSigners())[1])
          .setCustodian(governance.address),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
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
        ownerWallet.address,
        ownerWallet.address,
        [usdc.address],
        ownerWallet.address,
        usdc.address,
        usdc.address,
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
        ownerWallet.address,
        ownerWallet.address,
        [usdc.address],
        ownerWallet.address,
        usdc.address,
        usdc.address,
      );

      await governance.initiateExchangeUpgrade(newExchange.address);
      await expect(
        governance.initiateExchangeUpgrade(newExchange.address),
      ).to.eventually.be.rejectedWith(/exchange upgrade already in progress/i);
    });

    it('should revert when not called by admin', async () => {
      await expect(
        governance
          .connect((await ethers.getSigners())[1])
          .initiateExchangeUpgrade(governance.address),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
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
        ownerWallet.address,
        ownerWallet.address,
        [usdc.address],
        ownerWallet.address,
        usdc.address,
        usdc.address,
      );

      await governance.initiateExchangeUpgrade(newExchange.address);
      await governance.cancelExchangeUpgrade();
    });

    it('should revert when no upgrade was initiated', async () => {
      await expect(
        governance.cancelExchangeUpgrade(),
      ).to.eventually.be.rejectedWith(/no exchange upgrade in progress/i);
    });

    it('should revert when not called by admin', async () => {
      await expect(
        governance
          .connect((await ethers.getSigners())[1])
          .cancelExchangeUpgrade(),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });
  });

  describe('finalizeExchangeUpgrade', () => {
    let custodian: Custodian;
    let ExchangeFactory: Exchange_v4__factory;
    let governance: Governance;
    let ownerWallet: SignerWithAddress;
    let usdc: USDC;

    beforeEach(async () => {
      [ownerWallet] = await ethers.getSigners();
      const results = await deployAndAssociateContracts(ownerWallet);
      ExchangeFactory = results.ExchangeFactory;
      custodian = results.custodian;
      governance = results.governance;
      usdc = results.usdc;
    });

    it('should work when upgrade was initiated and addresses match', async () => {
      const newExchange = await ExchangeFactory.deploy(
        ethers.constants.AddressZero,
        ownerWallet.address,
        ownerWallet.address,
        [usdc.address],
        ownerWallet.address,
        usdc.address,
        usdc.address,
      );

      await governance.initiateExchangeUpgrade(newExchange.address);
      await governance.finalizeExchangeUpgrade(newExchange.address);

      await expect(custodian.exchange()).to.eventually.equal(
        newExchange.address,
      );
    });

    it('should revert when no upgrade was initiated', async () => {
      await expect(
        governance.finalizeExchangeUpgrade(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/no exchange upgrade in progress/i);
    });

    it('should revert when upgrade was initiated and addresses mismatch', async () => {
      const newExchange = await ExchangeFactory.deploy(
        ethers.constants.AddressZero,
        ownerWallet.address,
        ownerWallet.address,
        [usdc.address],
        ownerWallet.address,
        usdc.address,
        usdc.address,
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
        100,
      );
      governance = results.governance;
      const newExchange = await ExchangeFactory.deploy(
        ethers.constants.AddressZero,
        ownerWallet.address,
        ownerWallet.address,
        [usdc.address],
        ownerWallet.address,
        usdc.address,
        usdc.address,
      );

      await governance.initiateExchangeUpgrade(newExchange.address);
      await expect(
        governance.finalizeExchangeUpgrade(newExchange.address),
      ).to.eventually.be.rejectedWith(/block threshold not yet reached/i);
    });

    it('should revert when not called by admin', async () => {
      await expect(
        governance
          .connect((await ethers.getSigners())[1])
          .finalizeExchangeUpgrade(governance.address),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });
  });

  describe('initiateGovernanceUpgrade', () => {
    let governance: Governance;
    let newGovernance: Governance;
    let ownerWallet: SignerWithAddress;

    beforeEach(async () => {
      [ownerWallet] = await ethers.getSigners();
      const results = await deployAndAssociateContracts(ownerWallet);
      governance = results.governance;
      newGovernance = await GovernanceFactory.deploy(0);
    });

    it('should work for valid contract address', async () => {
      await governance.initiateGovernanceUpgrade(newGovernance.address);
    });

    it('should revert for zero address', async () => {
      await expect(
        governance.initiateGovernanceUpgrade(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/invalid address/i);
    });

    it('should revert for non-contract address', async () => {
      await expect(
        governance.initiateGovernanceUpgrade(ownerWallet.address),
      ).to.eventually.be.rejectedWith(/invalid address/i);
    });

    it('should revert for same address as current', async () => {
      await expect(
        governance.initiateGovernanceUpgrade(governance.address),
      ).to.eventually.be.rejectedWith(
        /must be different from current governance/i,
      );
    });

    it('should revert when upgrade is in progress', async () => {
      await governance.initiateGovernanceUpgrade(newGovernance.address);

      await expect(
        governance.initiateGovernanceUpgrade(newGovernance.address),
      ).to.eventually.be.rejectedWith(
        /governance upgrade already in progress/i,
      );
    });

    it('should revert when not called by admin', async () => {
      await expect(
        governance
          .connect((await ethers.getSigners())[1])
          .initiateGovernanceUpgrade(newGovernance.address),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });
  });

  describe('cancelGovernanceUpgrade', () => {
    let governance: Governance;
    let newGovernance: Governance;
    let ownerWallet: SignerWithAddress;

    beforeEach(async () => {
      [ownerWallet] = await ethers.getSigners();
      const results = await deployAndAssociateContracts(ownerWallet);
      governance = results.governance;
      newGovernance = await GovernanceFactory.deploy(0);
    });

    it('should work when upgrade was initiated', async () => {
      await governance.initiateGovernanceUpgrade(newGovernance.address);
      await governance.cancelGovernanceUpgrade();
    });

    it('should revert when no upgrade was initiated', async () => {
      await expect(
        governance.cancelGovernanceUpgrade(),
      ).to.eventually.be.rejectedWith(/no governance upgrade in progress/i);
    });

    it('should revert when not called by admin', async () => {
      await expect(
        governance
          .connect((await ethers.getSigners())[1])
          .cancelGovernanceUpgrade(),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });
  });

  describe('finalizeGovernanceUpgrade', () => {
    let governance: Governance;
    let newGovernance: Governance;
    let ownerWallet: SignerWithAddress;

    beforeEach(async () => {
      [ownerWallet] = await ethers.getSigners();
      const results = await deployAndAssociateContracts(ownerWallet);
      governance = results.governance;
      newGovernance = await GovernanceFactory.deploy(0);
    });

    it('should work when upgrade was initiated and addresses match', async () => {
      await governance.initiateGovernanceUpgrade(newGovernance.address);
      await governance.finalizeGovernanceUpgrade(newGovernance.address);
    });

    it('should revert when no upgrade was initiated', async () => {
      await expect(
        governance.finalizeGovernanceUpgrade(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/no governance upgrade in progress/i);
    });

    it('should revert when upgrade was initiated and addresses mismatch', async () => {
      await governance.initiateGovernanceUpgrade(newGovernance.address);
      await expect(
        governance.finalizeGovernanceUpgrade(governance.address),
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
        100,
      );
      governance = results.governance;

      await governance.initiateGovernanceUpgrade(newGovernance.address);
      await expect(
        governance.finalizeGovernanceUpgrade(newGovernance.address),
      ).to.eventually.be.rejectedWith(/block threshold not yet reached/i);
    });

    it('should revert when not called by admin', async () => {
      await expect(
        governance
          .connect((await ethers.getSigners())[1])
          .finalizeGovernanceUpgrade(governance.address),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });
  });
});
