import { ethers } from 'hardhat';

import {
  BalanceMigrationSourceMock__factory,
  Exchange_v4,
  Exchange_v4__factory,
  Governance,
  USDC,
} from '../typechain-types';
import {
  deployAndAssociateContracts,
  deployLibraryContracts,
  expect,
} from './helpers';

describe('Exchange', function () {
  describe('deploy', async function () {
    let BalanceMigrationSourceMockFactory: BalanceMigrationSourceMock__factory;
    let ExchangeFactory: Exchange_v4__factory;
    let usdc: USDC;

    beforeEach(async () => {
      BalanceMigrationSourceMockFactory = await ethers.getContractFactory(
        'BalanceMigrationSourceMock',
      );
      ExchangeFactory = await deployLibraryContracts();
      usdc = await (await ethers.getContractFactory('USDC')).deploy();
    });

    it('should work for zero address migration source', async () => {
      const [ownerWallet] = await ethers.getSigners();

      await ExchangeFactory.deploy(
        ethers.constants.AddressZero,
        ownerWallet.address,
        ownerWallet.address,
        [ownerWallet.address],
        ownerWallet.address,
        usdc.address,
      );
    });

    it('should work for contract migration source', async () => {
      const [ownerWallet] = await ethers.getSigners();

      const balanceMigrationSourceMock =
        await BalanceMigrationSourceMockFactory.deploy(0);

      await ExchangeFactory.deploy(
        balanceMigrationSourceMock.address,
        ownerWallet.address,
        ownerWallet.address,
        [ownerWallet.address],
        ownerWallet.address,
        usdc.address,
      );
    });

    it('should revert for non-contract migration source', async () => {
      const [ownerWallet] = await ethers.getSigners();

      await expect(
        ExchangeFactory.deploy(
          ownerWallet.address,
          ownerWallet.address,
          ownerWallet.address,
          [ownerWallet.address],
          ownerWallet.address,
          usdc.address,
        ),
      ).to.eventually.be.rejectedWith(/invalid migration source/i);
    });

    it('should revert for non-contract quote asset address', async () => {
      const [ownerWallet] = await ethers.getSigners();

      const balanceMigrationSourceMock =
        await BalanceMigrationSourceMockFactory.deploy(0);

      await expect(
        ExchangeFactory.deploy(
          balanceMigrationSourceMock.address,
          ownerWallet.address,
          ownerWallet.address,
          [ownerWallet.address],
          ownerWallet.address,
          ownerWallet.address,
        ),
      ).to.eventually.be.rejectedWith(/invalid quote asset address/i);
    });

    it('should revert for zero IPS wallet', async () => {
      const [ownerWallet] = await ethers.getSigners();

      const balanceMigrationSourceMock =
        await BalanceMigrationSourceMockFactory.deploy(0);

      await expect(
        ExchangeFactory.deploy(
          balanceMigrationSourceMock.address,
          ownerWallet.address,
          ownerWallet.address,
          [ethers.constants.AddressZero],
          ownerWallet.address,
          usdc.address,
        ),
      ).to.eventually.be.rejectedWith(/invalid IPS wallet/i);
    });

    it('should revert for zero IF wallet', async () => {
      const [ownerWallet] = await ethers.getSigners();

      await expect(
        ExchangeFactory.deploy(
          ethers.constants.AddressZero,
          ownerWallet.address,
          ownerWallet.address,
          [ownerWallet.address],
          ethers.constants.AddressZero,
          usdc.address,
        ),
      ).to.eventually.be.rejectedWith(/invalid IF wallet/i);
    });
  });

  describe('field upgrade governance setters', () => {
    let exchange: Exchange_v4;

    beforeEach(async () => {
      const [owner] = await ethers.getSigners();
      const results = await deployAndAssociateContracts(owner);
      exchange = results.exchange;
    });

    describe('setBridgeAdapters', async function () {
      it('should revert when not called by Governance', async () => {
        await expect(
          exchange.setBridgeAdapters([]),
        ).to.eventually.be.rejectedWith(/caller must be governance contract/i);
      });
    });

    describe('setIndexPriceServiceWallets', async function () {
      it('should revert when not called by Governance', async () => {
        await expect(
          exchange.setIndexPriceServiceWallets([]),
        ).to.eventually.be.rejectedWith(/caller must be governance contract/i);
      });
    });

    describe('setInsuranceFundWallet', async function () {
      it('should revert when not called by Governance', async () => {
        await expect(
          exchange.setInsuranceFundWallet(ethers.constants.AddressZero),
        ).to.eventually.be.rejectedWith(/caller must be governance contract/i);
      });
    });
  });

  describe('setCustodian', async function () {
    let exchange: Exchange_v4;
    let ExchangeFactory: Exchange_v4__factory;
    let governance: Governance;
    let usdc: USDC;

    beforeEach(async () => {
      const [owner] = await ethers.getSigners();
      const results = await deployAndAssociateContracts(owner);
      exchange = results.exchange;
      ExchangeFactory = results.ExchangeFactory;
      governance = results.governance;
      usdc = results.usdc;
    });

    it('should work for valid Custodian and bridge adapters', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const newExchange = await ExchangeFactory.deploy(
        ethers.constants.AddressZero,
        ownerWallet.address,
        ownerWallet.address,
        [usdc.address],
        ownerWallet.address,
        usdc.address,
      );

      const CustodianFactory = await ethers.getContractFactory('Custodian');
      const custodian = await CustodianFactory.deploy(
        newExchange.address,
        newExchange.address,
      );

      await expect(
        newExchange.setCustodian(custodian.address, [
          ethers.constants.AddressZero,
        ]),
      ).to.eventually.be.rejectedWith(/invalid adapter address/i);
    });

    it('should revert for zero address', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const newExchange = await ExchangeFactory.deploy(
        ethers.constants.AddressZero,
        ownerWallet.address,
        ownerWallet.address,
        [ownerWallet.address],
        ownerWallet.address,
        usdc.address,
      );

      await expect(
        newExchange.setCustodian(ethers.constants.AddressZero, []),
      ).to.eventually.be.rejectedWith(/invalid address/i);
    });

    it('should revert for non-contract address', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const newExchange = await ExchangeFactory.deploy(
        ethers.constants.AddressZero,
        ownerWallet.address,
        ownerWallet.address,
        [ownerWallet.address],
        ownerWallet.address,
        usdc.address,
      );

      await expect(
        newExchange.setCustodian((await ethers.getSigners())[1].address, []),
      ).to.eventually.be.rejectedWith(/invalid address/i);
    });

    it('should revert when already set', async () => {
      await expect(
        exchange.setCustodian(ethers.constants.AddressZero, []),
      ).to.eventually.be.rejectedWith(/custodian can only be set once/i);
    });

    it('should revert when not called by admin', async () => {
      await expect(
        exchange
          .connect((await ethers.getSigners())[1])
          .setCustodian(governance.address, []),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });

    it('should revert for non-contract adapter address', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const newExchange = await ExchangeFactory.deploy(
        ethers.constants.AddressZero,
        ownerWallet.address,
        ownerWallet.address,
        [ownerWallet.address],
        ownerWallet.address,
        usdc.address,
      );

      const CustodianFactory = await ethers.getContractFactory('Custodian');
      const custodian = await CustodianFactory.deploy(
        newExchange.address,
        newExchange.address,
      );

      await expect(
        newExchange.setCustodian(custodian.address, [
          ethers.constants.AddressZero,
        ]),
      ).to.eventually.be.rejectedWith(/invalid adapter address/i);
    });
  });

  describe('removeDispatcher', async function () {
    let exchange: Exchange_v4;

    beforeEach(async () => {
      const [owner] = await ethers.getSigners();
      const results = await deployAndAssociateContracts(owner);
      exchange = results.exchange;
    });

    it('should work', async () => {
      await exchange.removeDispatcher();
      await expect(exchange.dispatcherWallet()).to.eventually.equal(
        ethers.constants.AddressZero,
      );
    });

    it('should revert when not called by admin', async () => {
      await expect(
        exchange.connect((await ethers.getSigners())[1]).removeDispatcher(),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });
  });

  describe('setDepositIndex', () => {
    let exchange: Exchange_v4;

    beforeEach(async () => {
      const [owner] = await ethers.getSigners();
      const results = await deployAndAssociateContracts(owner);
      exchange = results.exchange;
    });

    it('should revert when called more than once', async () => {
      await expect(exchange.setDepositIndex()).to.eventually.be.rejectedWith(
        /can only be set once/i,
      );
    });
  });
});
