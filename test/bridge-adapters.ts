import { time } from '@nomicfoundation/hardhat-network-helpers';
import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { v1 as uuidv1 } from 'uuid';
import { ethers, network } from 'hardhat';

import type {
  Custodian,
  Exchange_v4,
  ExchangeStargateAdapter,
  ExchangeStargateAdapter__factory,
  Governance,
  StargateRouterMock,
  USDC,
} from '../typechain-types';
import {
  decimalToAssetUnits,
  decimalToPips,
  fieldUpgradeDelayInS,
  getWithdrawArguments,
  getWithdrawalSignatureTypedData,
  Withdrawal,
} from '../lib';
import {
  deployAndAssociateContracts,
  expect,
  quoteAssetDecimals,
} from './helpers';

describe('ExchangeStargateAdapter', function () {
  let custodian: Custodian;
  let dispatcherWallet: SignerWithAddress;
  let exchange: Exchange_v4;
  let ExchangeStargateAdapterFactory: ExchangeStargateAdapter__factory;
  let governance: Governance;
  let ownerWallet: SignerWithAddress;
  const routerFee = ethers.parseEther('0.0001');
  let stargateRouterMock: StargateRouterMock;
  let traderWallet: SignerWithAddress;
  let usdc: USDC;

  before(async () => {
    await network.provider.send('hardhat_reset');
  });

  beforeEach(async () => {
    const wallets = await ethers.getSigners();

    ownerWallet = wallets[0];
    dispatcherWallet = wallets[1];
    traderWallet = wallets[6];
    const results = await deployAndAssociateContracts(
      ownerWallet,
      dispatcherWallet,
      wallets[2],
      wallets[3],
      wallets[4],
      wallets[5],
    );
    custodian = results.custodian;
    exchange = results.exchange;
    governance = results.governance;
    usdc = results.usdc;

    await usdc.transfer(
      traderWallet.address,
      decimalToAssetUnits('1000.00000000', quoteAssetDecimals),
    );

    ExchangeStargateAdapterFactory = await ethers.getContractFactory(
      'ExchangeStargateAdapter',
    );
    stargateRouterMock = await (
      await ethers.getContractFactory('StargateRouterMock')
    ).deploy(routerFee, await usdc.getAddress());
  });

  describe('deploy', async function () {
    it('should work for valid arguments', async () => {
      await ExchangeStargateAdapterFactory.deploy(
        await custodian.getAddress(),
        decimalToPips('0.99900000'),
        await stargateRouterMock.getAddress(),
        await usdc.getAddress(),
      );
    });

    it('should revert for invalid Custodian address', async () => {
      await expect(
        ExchangeStargateAdapterFactory.deploy(
          ethers.ZeroAddress,
          decimalToPips('0.99900000'),
          await stargateRouterMock.getAddress(),
          await usdc.getAddress(),
        ),
      ).to.eventually.be.rejectedWith(/invalid custodian address/i);
    });

    it('should revert for invalid Router address', async () => {
      await expect(
        ExchangeStargateAdapterFactory.deploy(
          await custodian.getAddress(),
          decimalToPips('0.99900000'),
          ethers.ZeroAddress,
          await usdc.getAddress(),
        ),
      ).to.eventually.be.rejectedWith(/invalid custodian address/i);
    });

    it('should revert for invalid quote asset address', async () => {
      await expect(
        ExchangeStargateAdapterFactory.deploy(
          await custodian.getAddress(),
          decimalToPips('0.99900000'),
          await stargateRouterMock.getAddress(),
          ethers.ZeroAddress,
        ),
      ).to.eventually.be.rejectedWith(/invalid quote asset address/i);
    });
  });

  describe('sgReceive', async function () {
    let adapter: ExchangeStargateAdapter;

    beforeEach(async () => {
      adapter = await ExchangeStargateAdapterFactory.deploy(
        await custodian.getAddress(),
        decimalToPips('0.99900000'),
        await stargateRouterMock.getAddress(),
        await usdc.getAddress(),
      );
    });

    it('should work for valid arguments', async () => {
      const depositQuantityInAssetUnits = decimalToAssetUnits(
        '1.00000000',
        quoteAssetDecimals,
      );
      await usdc.transfer(
        await adapter.getAddress(),
        depositQuantityInAssetUnits,
      );
      await adapter.setDepositEnabled(true);

      await stargateRouterMock.sgReceive(
        await adapter.getAddress(),
        1,
        '0x',
        0,
        await usdc.getAddress(),
        depositQuantityInAssetUnits,
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['address'],
          [ownerWallet.address],
        ),
      );
    });

    it('should revert when not sent by Router', async () => {
      const depositQuantityInAssetUnits = decimalToAssetUnits(
        '1.00000000',
        quoteAssetDecimals,
      );
      await usdc.transfer(
        await adapter.getAddress(),
        depositQuantityInAssetUnits,
      );
      await adapter.setDepositEnabled(true);

      await expect(
        adapter.sgReceive(
          1,
          '0x',
          0,
          await usdc.getAddress(),
          depositQuantityInAssetUnits,
          ethers.AbiCoder.defaultAbiCoder().encode(
            ['address'],
            [ownerWallet.address],
          ),
        ),
      ).to.eventually.be.rejectedWith(/caller must be router/i);
    });

    it('should revert when deposits are disabled', async () => {
      await expect(
        stargateRouterMock.sgReceive(
          await adapter.getAddress(),
          1,
          '0x',
          0,
          await usdc.getAddress(),
          10000000000,
          ethers.AbiCoder.defaultAbiCoder().encode(
            ['address'],
            [ownerWallet.address],
          ),
        ),
      ).to.eventually.be.rejectedWith(/deposits disabled/i);
    });

    it('should revert for invalid quote asset address', async () => {
      await adapter.setDepositEnabled(true);

      await expect(
        stargateRouterMock.sgReceive(
          await adapter.getAddress(),
          1,
          '0x',
          0,
          ethers.ZeroAddress,
          10000000000,
          ethers.AbiCoder.defaultAbiCoder().encode(
            ['address'],
            [ethers.ZeroAddress],
          ),
        ),
      ).to.eventually.be.rejectedWith(/invalid token/i);
    });

    it('should revert for invalid destination wallet', async () => {
      await adapter.setDepositEnabled(true);

      await expect(
        stargateRouterMock.sgReceive(
          await adapter.getAddress(),
          1,
          '0x',
          0,
          await usdc.getAddress(),
          10000000000,
          ethers.AbiCoder.defaultAbiCoder().encode(
            ['address'],
            [ethers.ZeroAddress],
          ),
        ),
      ).to.eventually.be.rejectedWith(/invalid destination wallet/i);
    });
  });

  describe('withdrawQuoteAsset', async function () {
    let adapter: ExchangeStargateAdapter;
    let signature: string;
    let withdrawal: Withdrawal;

    beforeEach(async () => {
      adapter = await ExchangeStargateAdapterFactory.deploy(
        await custodian.getAddress(),
        decimalToPips('0.99900000'),
        await stargateRouterMock.getAddress(),
        await usdc.getAddress(),
      );

      await governance.initiateBridgeAdaptersUpgrade([
        await adapter.getAddress(),
      ]);
      await time.increase(fieldUpgradeDelayInS);
      await governance.finalizeBridgeAdaptersUpgrade([
        await adapter.getAddress(),
      ]);

      await adapter.setWithdrawEnabled(true);

      const depositQuantity = ethers.parseUnits('5.0', quoteAssetDecimals);
      await usdc.transfer(traderWallet.address, depositQuantity);
      await usdc
        .connect(traderWallet)
        .approve(await exchange.getAddress(), depositQuantity);
      await exchange
        .connect(traderWallet)
        .deposit(depositQuantity, ethers.ZeroAddress);
      await exchange
        .connect(dispatcherWallet)
        .applyPendingDepositsForWallet(
          decimalToPips('5.00000000'),
          traderWallet.address,
        );

      withdrawal = {
        nonce: uuidv1(),
        wallet: traderWallet.address,
        quantity: '1.00000000',
        maximumGasFee: '0.10000000',
        bridgeAdapter: await adapter.getAddress(),
        bridgeAdapterPayload: ethers.AbiCoder.defaultAbiCoder().encode(
          ['uint16', 'uint256', 'uint256'],
          [1, 1, 1],
        ),
      };
      signature = await traderWallet.signTypedData(
        ...getWithdrawalSignatureTypedData(
          withdrawal,
          await exchange.getAddress(),
        ),
      );
    });

    it('should work for valid arguments when adapter is funded', async () => {
      await ownerWallet.sendTransaction({
        to: await adapter.getAddress(),
        value: routerFee,
      });

      await exchange
        .connect(dispatcherWallet)
        .withdraw(...getWithdrawArguments(withdrawal, '0.00000000', signature));
    });

    it('should work for when multiple adapters are whitelisted', async () => {
      await ownerWallet.sendTransaction({
        to: await adapter.getAddress(),
        value: routerFee,
      });

      ExchangeStargateAdapterFactory = await ethers.getContractFactory(
        'ExchangeStargateAdapter',
      );
      const adapter2 = await (
        await ethers.getContractFactory('StargateRouterMock')
      ).deploy(routerFee, await usdc.getAddress());

      await governance.initiateBridgeAdaptersUpgrade([
        await adapter2.getAddress(),
        await adapter.getAddress(),
      ]);
      await time.increase(fieldUpgradeDelayInS);
      await governance.finalizeBridgeAdaptersUpgrade([
        await adapter2.getAddress(),
        await adapter.getAddress(),
      ]);

      await exchange
        .connect(dispatcherWallet)
        .withdraw(...getWithdrawArguments(withdrawal, '0.00000000', signature));
    });

    it('should work with fallback for valid arguments when adapter is not funded', async () => {
      await exchange
        .connect(dispatcherWallet)
        .withdraw(...getWithdrawArguments(withdrawal, '0.00000000', signature));
    });

    it('should revert if not called by Exchange', async () => {
      await expect(
        adapter.withdrawQuoteAsset(ownerWallet.address, 1000, '0x'),
      ).to.eventually.be.rejectedWith(/caller must be exchange/i);
    });

    it('should revert if withdrawals are disabled', async () => {
      await adapter.setWithdrawEnabled(false);

      await expect(
        exchange
          .connect(dispatcherWallet)
          .withdraw(
            ...getWithdrawArguments(withdrawal, '0.00000000', signature),
          ),
      ).to.eventually.be.rejectedWith(/withdraw disabled/i);
    });
  });

  describe('setDepositEnabled', async function () {
    let adapter: ExchangeStargateAdapter;

    beforeEach(async () => {
      adapter = await ExchangeStargateAdapterFactory.deploy(
        await custodian.getAddress(),
        decimalToPips('0.99900000'),
        await stargateRouterMock.getAddress(),
        await usdc.getAddress(),
      );
    });

    it('should revert when caller is not admin', async () => {
      await expect(
        adapter
          .connect((await ethers.getSigners())[10])
          .setDepositEnabled(true),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });
  });

  describe('setWithdrawEnabled', async function () {
    let adapter: ExchangeStargateAdapter;

    beforeEach(async () => {
      adapter = await ExchangeStargateAdapterFactory.deploy(
        await custodian.getAddress(),
        decimalToPips('0.99900000'),
        await stargateRouterMock.getAddress(),
        await usdc.getAddress(),
      );
    });

    it('should revert when caller is not admin', async () => {
      await expect(
        adapter
          .connect((await ethers.getSigners())[10])
          .setWithdrawEnabled(true),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });
  });

  describe('setMinimumWithdrawQuantityMultiplier', async function () {
    let adapter: ExchangeStargateAdapter;

    beforeEach(async () => {
      adapter = await ExchangeStargateAdapterFactory.deploy(
        await custodian.getAddress(),
        decimalToPips('0.99900000'),
        await stargateRouterMock.getAddress(),
        await usdc.getAddress(),
      );
    });

    it('should work when caller is admin', async () => {
      await adapter.setMinimumWithdrawQuantityMultiplier(1000000);
    });

    it('should revert when caller is not admin', async () => {
      await expect(
        adapter
          .connect((await ethers.getSigners())[10])
          .setMinimumWithdrawQuantityMultiplier(1000000),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });
  });

  describe('skimToken', async function () {
    let adapter: ExchangeStargateAdapter;

    beforeEach(async () => {
      adapter = await ExchangeStargateAdapterFactory.deploy(
        await custodian.getAddress(),
        decimalToPips('0.99900000'),
        await stargateRouterMock.getAddress(),
        await usdc.getAddress(),
      );
    });

    it('should work when caller is admin', async () => {
      await usdc.transfer(await adapter.getAddress(), 10000);
      await adapter.skimToken(await usdc.getAddress(), traderWallet.address);
    });

    it('should revert when caller is not admin', async () => {
      await expect(
        adapter
          .connect((await ethers.getSigners())[10])
          .skimToken(await usdc.getAddress(), traderWallet.address),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });

    it('should revert for non-token address', async () => {
      await expect(
        adapter.skimToken(ethers.ZeroAddress, traderWallet.address),
      ).to.eventually.be.rejectedWith(/invalid token address/i);
    });
  });

  describe('withdrawNativeAsset', async function () {
    let adapter: ExchangeStargateAdapter;

    beforeEach(async () => {
      adapter = await ExchangeStargateAdapterFactory.deploy(
        await custodian.getAddress(),
        decimalToPips('0.99900000'),
        await stargateRouterMock.getAddress(),
        await usdc.getAddress(),
      );
      await ownerWallet.sendTransaction({
        to: await adapter.getAddress(),
        value: ethers.parseEther('1.0'),
      });
    });

    it('should work when caller is admin', async () => {
      await adapter.withdrawNativeAsset(
        traderWallet.address,
        ethers.parseEther('1.0'),
      );
    });

    it('should revert when caller is not admin', async () => {
      await expect(
        adapter
          .connect((await ethers.getSigners())[10])
          .withdrawNativeAsset(traderWallet.address, ethers.parseEther('1.0')),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });
  });
});
