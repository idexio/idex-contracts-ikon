import { ethers } from 'hardhat';

import {
  BalanceMigrationSourceMock__factory,
  Exchange_v4__factory,
  USDC,
} from '../typechain-types';
import { deployLibraryContracts, expect } from './helpers';

describe('Exchange', function () {
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

  describe('deploy', async function () {
    it('should work for zero address migration source', async () => {
      const [ownerWallet] = await ethers.getSigners();

      await ExchangeFactory.deploy(
        ethers.constants.AddressZero,
        usdc.address,
        ownerWallet.address,
        ownerWallet.address,
        ownerWallet.address,
        [ownerWallet.address],
      );
    });

    it('should work for contract migration source', async () => {
      const [ownerWallet] = await ethers.getSigners();

      const balanceMigrationSourceMock =
        await BalanceMigrationSourceMockFactory.deploy(0);

      await ExchangeFactory.deploy(
        balanceMigrationSourceMock.address,
        usdc.address,
        ownerWallet.address,
        ownerWallet.address,
        ownerWallet.address,
        [ownerWallet.address],
      );
    });

    it('should revert for non-contract migration source', async () => {
      const [ownerWallet] = await ethers.getSigners();

      await expect(
        ExchangeFactory.deploy(
          ownerWallet.address,
          usdc.address,
          ownerWallet.address,
          ownerWallet.address,
          ownerWallet.address,
          [ownerWallet.address],
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
          ownerWallet.address,
          ownerWallet.address,
          [ownerWallet.address],
        ),
      ).to.eventually.be.rejectedWith(/invalid quote asset address/i);
    });

    it('should revert for zero IPCS wallet', async () => {
      const [ownerWallet] = await ethers.getSigners();

      const balanceMigrationSourceMock =
        await BalanceMigrationSourceMockFactory.deploy(0);

      await expect(
        ExchangeFactory.deploy(
          balanceMigrationSourceMock.address,
          usdc.address,
          ownerWallet.address,
          ownerWallet.address,
          ownerWallet.address,
          [ethers.constants.AddressZero],
        ),
      ).to.eventually.be.rejectedWith(/invalid quote asset address/i);
    });
  });
});
