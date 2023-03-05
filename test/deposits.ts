import { expect } from 'chai';
import { ethers } from 'hardhat';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

import { decimalToAssetUnits, decimalToPips, pipsToAssetUnits } from '../lib';
import type {
  BalanceMigrationSourceMock,
  Exchange_v4,
  USDC,
} from '../typechain-types';
import {
  deployAndAssociateContracts,
  quoteAssetDecimals,
  quoteAssetSymbol,
} from './helpers';

describe('Exchange', function () {
  let balanceMigrationSource: BalanceMigrationSourceMock;
  let exchange: Exchange_v4;
  let ownerWallet: SignerWithAddress;
  let traderWallet: SignerWithAddress;
  let usdc: USDC;

  beforeEach(async () => {
    const wallets = await ethers.getSigners();

    const BalanceMigrationSourceMockFactory = await ethers.getContractFactory(
      'BalanceMigrationSourceMock',
    );
    balanceMigrationSource = await BalanceMigrationSourceMockFactory.deploy(0);

    ownerWallet = wallets[0];
    traderWallet = wallets[6];
    const results = await deployAndAssociateContracts(
      ownerWallet,
      wallets[1],
      wallets[2],
      wallets[3],
      wallets[4],
      wallets[5],
      0,
      false,
      balanceMigrationSource.address,
    );
    exchange = results.exchange;
    usdc = results.usdc;

    await usdc.transfer(
      traderWallet.address,
      decimalToAssetUnits('1000.00000000', quoteAssetDecimals),
    );
  });

  describe('deposit', function () {
    it('should work', async function () {
      const depositQuantity = ethers.utils.parseUnits(
        '5.0',
        quoteAssetDecimals,
      );
      await usdc.transfer(traderWallet.address, depositQuantity);
      await usdc
        .connect(traderWallet)
        .approve(exchange.address, depositQuantity);
      await exchange
        .connect(traderWallet)
        .deposit(depositQuantity, ethers.constants.AddressZero);

      const depositedEvents = await exchange.queryFilter(
        exchange.filters.Deposited(),
      );

      expect(depositedEvents).to.have.lengthOf(1);
      expect(depositedEvents[0].args?.quantity).to.equal(
        decimalToPips('5.00000000'),
      );
    });

    it('should migrate balance on deposit', async () => {
      const migratedBalanceQuantity = decimalToPips('100.00000000');
      await balanceMigrationSource.setBalanceBySymbol(
        traderWallet.address,
        quoteAssetSymbol,
        migratedBalanceQuantity,
      );

      await usdc.approve(
        exchange.address,
        pipsToAssetUnits(migratedBalanceQuantity, quoteAssetDecimals),
      );
      await exchange.deposit(
        pipsToAssetUnits(migratedBalanceQuantity, quoteAssetDecimals),
        traderWallet.address,
      );

      const depositedEvents = await exchange.queryFilter(
        exchange.filters.Deposited(),
      );
      expect(depositedEvents).to.be.an('array').with.lengthOf(1);
      expect(depositedEvents[0].args?.destinationWallet).to.equal(
        traderWallet.address,
      );
      expect(depositedEvents[0].args?.quantity.toString()).to.equal(
        migratedBalanceQuantity,
      );

      const expectedQuantity = (
        BigInt(migratedBalanceQuantity) * BigInt(2)
      ).toString();
      expect(
        (
          await exchange.loadBalanceBySymbol(
            traderWallet.address,
            quoteAssetSymbol,
          )
        ).toString(),
      ).to.equal(expectedQuantity);
    });

    it('should fail for exited source wallet', async function () {
      await exchange.connect(traderWallet).exitWallet();
      await expect(
        exchange
          .connect(traderWallet)
          .deposit('10000000', ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/source wallet exited/i);
    });

    it('should fail for exited destination wallet', async function () {
      await exchange.connect(ownerWallet).exitWallet();
      await expect(
        exchange.connect(traderWallet).deposit('10000000', ownerWallet.address),
      ).to.eventually.be.rejectedWith(/destination wallet exited/i);
    });
  });
});
