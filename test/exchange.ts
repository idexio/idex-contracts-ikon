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

      await ExchangeFactory.deploy({
        balanceMigrationSource: ethers.constants.AddressZero,
        exitFundWallet: ownerWallet.address,
        feeWallet: ownerWallet.address,
        indexPriceServiceWallets: [ownerWallet.address],
        insuranceFundWallet: ownerWallet.address,
        quoteAssetAddress: usdc.address,
      });
    });

    it('should work for contract migration source', async () => {
      const [ownerWallet] = await ethers.getSigners();

      const balanceMigrationSourceMock =
        await BalanceMigrationSourceMockFactory.deploy(0);

      await ExchangeFactory.deploy({
        balanceMigrationSource: balanceMigrationSourceMock.address,
        exitFundWallet: ownerWallet.address,
        feeWallet: ownerWallet.address,
        indexPriceServiceWallets: [ownerWallet.address],
        insuranceFundWallet: ownerWallet.address,
        quoteAssetAddress: usdc.address,
      });
    });

    it('should revert for non-contract migration source', async () => {
      const [ownerWallet] = await ethers.getSigners();

      await expect(
        ExchangeFactory.deploy({
          balanceMigrationSource: ownerWallet.address,
          exitFundWallet: ownerWallet.address,
          feeWallet: ownerWallet.address,
          indexPriceServiceWallets: [ownerWallet.address],
          insuranceFundWallet: ownerWallet.address,
          quoteAssetAddress: usdc.address,
        }),
      ).to.eventually.be.rejectedWith(/invalid migration source/i);
    });

    it('should revert for non-contract quote asset address', async () => {
      const [ownerWallet] = await ethers.getSigners();

      const balanceMigrationSourceMock =
        await BalanceMigrationSourceMockFactory.deploy(0);

      await expect(
        ExchangeFactory.deploy({
          balanceMigrationSource: balanceMigrationSourceMock.address,
          exitFundWallet: ownerWallet.address,
          feeWallet: ownerWallet.address,
          indexPriceServiceWallets: [ownerWallet.address],
          insuranceFundWallet: ownerWallet.address,
          quoteAssetAddress: ownerWallet.address,
        }),
      ).to.eventually.be.rejectedWith(/invalid quote asset address/i);
    });

    it('should revert for zero IPS wallet', async () => {
      const [ownerWallet] = await ethers.getSigners();

      const balanceMigrationSourceMock =
        await BalanceMigrationSourceMockFactory.deploy(0);

      await expect(
        ExchangeFactory.deploy({
          balanceMigrationSource: balanceMigrationSourceMock.address,
          exitFundWallet: ownerWallet.address,
          feeWallet: ownerWallet.address,
          indexPriceServiceWallets: [ethers.constants.AddressZero],
          insuranceFundWallet: ownerWallet.address,
          quoteAssetAddress: ownerWallet.address,
        }),
      ).to.eventually.be.rejectedWith(/invalid quote asset address/i);
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

    it('should revert for zero address', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const newExchange = await ExchangeFactory.deploy({
        balanceMigrationSource: ethers.constants.AddressZero,
        exitFundWallet: ownerWallet.address,
        feeWallet: ownerWallet.address,
        indexPriceServiceWallets: [ownerWallet.address],
        insuranceFundWallet: ownerWallet.address,
        quoteAssetAddress: usdc.address,
      });

      await expect(
        newExchange.setCustodian(ethers.constants.AddressZero, []),
      ).to.eventually.be.rejectedWith(/invalid address/i);
    });

    it('should revert for non-contract address', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const newExchange = await ExchangeFactory.deploy({
        balanceMigrationSource: ethers.constants.AddressZero,
        exitFundWallet: ownerWallet.address,
        feeWallet: ownerWallet.address,
        indexPriceServiceWallets: [ownerWallet.address],
        insuranceFundWallet: ownerWallet.address,
        quoteAssetAddress: usdc.address,
      });

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
  });
});
