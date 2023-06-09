import BigNumber from 'bignumber.js';
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
  deployLibraryContracts,
  expect,
  quoteAssetDecimals,
  quoteAssetSymbol,
} from './helpers';

describe('Exchange', function () {
  let balanceMigrationSource: BalanceMigrationSourceMock;
  let exchange: Exchange_v4;
  let exitFundWallet: SignerWithAddress;
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
    exitFundWallet = wallets[2];
    traderWallet = wallets[6];
    const results = await deployAndAssociateContracts(
      ownerWallet,
      wallets[1],
      exitFundWallet,
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
      await expect(usdc.decimals()).to.eventually.equal(quoteAssetDecimals);

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
      expect(depositedEvents[0].args?.newExchangeBalance).to.equal(
        decimalToPips('5.00000000'),
      );
      expect(
        (
          await exchange.loadBalanceBySymbol(
            traderWallet.address,
            quoteAssetSymbol,
          )
        ).toString(),
      ).to.equal(decimalToPips('5.00000000'));
    });

    it('should work with fee', async function () {
      await expect(usdc.decimals()).to.eventually.equal(quoteAssetDecimals);

      const depositQuantity = ethers.utils.parseUnits(
        '5.0',
        quoteAssetDecimals,
      );
      const feeQuantity = ethers.utils.parseUnits('0.5', quoteAssetDecimals);

      await usdc.transfer(traderWallet.address, depositQuantity);
      await usdc
        .connect(traderWallet)
        .approve(exchange.address, depositQuantity);
      await usdc.setFee(feeQuantity);
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
      expect(depositedEvents[0].args?.newExchangeBalance).to.equal(
        decimalToPips('4.50000000'),
      );
      expect(
        (
          await exchange.loadBalanceBySymbol(
            traderWallet.address,
            quoteAssetSymbol,
          )
        ).toString(),
      ).to.equal(decimalToPips('4.50000000'));
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

    it('should revert depositing to EF', async function () {
      await expect(
        exchange
          .connect(traderWallet)
          .deposit('1000000', exitFundWallet.address),
      ).to.eventually.be.rejectedWith(/cannot deposit to EF/i);
    });

    it('should revert for zero quantity', async function () {
      await expect(
        exchange
          .connect(traderWallet)
          .deposit('0', ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/quantity is too low/i);
    });

    it('should revert for too large quantity', async function () {
      await expect(
        exchange
          .connect(traderWallet)
          .deposit(
            new BigNumber(2).pow(63 - quoteAssetDecimals).toString(),
            ethers.constants.AddressZero,
          ),
      ).to.eventually.be.rejectedWith(/quantity is too large/i);
    });

    it('should revert for exited source wallet', async function () {
      await exchange.connect(traderWallet).exitWallet();
      await expect(
        exchange
          .connect(traderWallet)
          .deposit('10000000', ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/source wallet exited/i);
    });

    it('should revert for exited destination wallet', async function () {
      await exchange.connect(ownerWallet).exitWallet();
      await expect(
        exchange.connect(traderWallet).deposit('10000000', ownerWallet.address),
      ).to.eventually.be.rejectedWith(/destination wallet exited/i);
    });

    it('should revert when deposit index is unset', async function () {
      const ExchangeFactory = await deployLibraryContracts();
      const newExchange = await ExchangeFactory.deploy(
        ethers.constants.AddressZero,
        ownerWallet.address,
        ownerWallet.address,
        [usdc.address],
        ownerWallet.address,
        usdc.address,
        usdc.address,
      );

      await expect(
        newExchange
          .connect(traderWallet)
          .deposit('10000000', ownerWallet.address),
      ).to.eventually.be.rejectedWith(/deposits disabled/i);
    });

    it('should revert when deposits are disabled', async function () {
      await exchange.setDepositEnabled(false);

      await expect(
        exchange.connect(traderWallet).deposit('10000000', ownerWallet.address),
      ).to.eventually.be.rejectedWith(/deposits disabled/i);
    });
  });

  describe('setDepositEnabled', function () {
    it('should work', async function () {
      await expect(exchange.isDepositEnabled()).to.eventually.equal(true);
      let events = await exchange.queryFilter(
        exchange.filters.DepositsEnabled(),
      );
      expect(events).to.have.lengthOf(1);

      await exchange.setDepositEnabled(false);

      await expect(exchange.isDepositEnabled()).to.eventually.equal(false);
      events = await exchange.queryFilter(exchange.filters.DepositsDisabled());
      expect(events).to.have.lengthOf(1);
    });

    it('should revert when not sent by admin', async function () {
      await expect(
        exchange.connect(traderWallet).setDepositEnabled(false),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });

    it('should revert when already enabled', async function () {
      await expect(
        exchange.setDepositEnabled(true),
      ).to.eventually.be.rejectedWith(/deposits already enabled/i);
    });

    it('should revert when already disabled', async function () {
      await exchange.setDepositEnabled(false);

      await expect(
        exchange.setDepositEnabled(false),
      ).to.eventually.be.rejectedWith(/deposits already disabled/i);
    });
  });
});
