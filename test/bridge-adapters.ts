import { time } from '@nomicfoundation/hardhat-network-helpers';
import { ethers, network } from 'hardhat';
import { v1 as uuidv1 } from 'uuid';

import {
  decimalToAssetUnits,
  decimalToPips,
  fieldUpgradeDelayInS,
  getWithdrawArguments,
  getWithdrawalSignatureTypedData,
} from '../lib';

import {
  deployAndAssociateContracts,
  expect,
  quoteAssetDecimals,
} from './helpers';

import type { Withdrawal } from '../lib';
import type {
  Custodian,
  Exchange_v4,
  ExchangeStargateAdapter,
  ExchangeStargateAdapter__factory,
  ExchangeStargateV2Adapter__factory,
  Governance,
  StargateRouterMock,
  USDC,
  StargateV2PoolMock,
} from '../typechain-types';
import type { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';

describe('bridge-adapters', function () {
  describe('ExchangeStargateV2AdapterV2', function () {
    let custodian: Custodian;
    let dispatcherWallet: SignerWithAddress;
    let exchange: Exchange_v4;
    let ExchangeStargateV2AdapterFactory: ExchangeStargateV2Adapter__factory;
    let ownerWallet: SignerWithAddress;
    let stargatePoolMock: StargateV2PoolMock;
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
      usdc = results.usdc;

      await usdc.transfer(
        traderWallet.address,
        decimalToAssetUnits('1000.00000000', quoteAssetDecimals),
      );

      ExchangeStargateV2AdapterFactory = await ethers.getContractFactory(
        'ExchangeStargateV2Adapter',
      );
      stargatePoolMock = await (
        await ethers.getContractFactory('StargateV2PoolMock')
      ).deploy(await usdc.getAddress());
    });

    describe('deploy', async function () {
      it('should work for valid arguments', async () => {
        await ExchangeStargateV2AdapterFactory.deploy(
          await custodian.getAddress(),
          decimalToPips('0.99900000'),
          await stargatePoolMock.getAddress(),
          await stargatePoolMock.getAddress(),
          await usdc.getAddress(),
        );
      });

      it('should revert for invalid Custodian address', async () => {
        await expect(
          ExchangeStargateV2AdapterFactory.deploy(
            ethers.ZeroAddress,
            decimalToPips('0.99900000'),
            await stargatePoolMock.getAddress(),
            await stargatePoolMock.getAddress(),
            await usdc.getAddress(),
          ),
        ).to.eventually.be.rejectedWith(/invalid custodian address/i);
      });

      it('should revert for invalid Stargate pool address', async () => {
        await expect(
          ExchangeStargateV2AdapterFactory.deploy(
            await custodian.getAddress(),
            decimalToPips('0.99900000'),
            await stargatePoolMock.getAddress(),
            ethers.ZeroAddress,
            await usdc.getAddress(),
          ),
        ).to.eventually.be.rejectedWith(/invalid stargate address/i);
      });

      it('should revert for invalid LZ endpoint address', async () => {
        await expect(
          ExchangeStargateV2AdapterFactory.deploy(
            await custodian.getAddress(),
            decimalToPips('0.99900000'),
            ethers.ZeroAddress,
            await stargatePoolMock.getAddress(),
            await usdc.getAddress(),
          ),
        ).to.eventually.be.rejectedWith(/invalid lz endpoint address/i);
      });

      it('should revert for invalid quote asset address', async () => {
        await expect(
          ExchangeStargateV2AdapterFactory.deploy(
            await custodian.getAddress(),
            decimalToPips('0.99900000'),
            await stargatePoolMock.getAddress(),
            await stargatePoolMock.getAddress(),
            ethers.ZeroAddress,
          ),
        ).to.eventually.be.rejectedWith(/invalid quote asset address/i);
      });
    });

    describe('lzCompose', async function () {
      it('should work for valid arguments', async () => {
        const depositQuantityInDecimal = '5.00000000';
        const depositQuantityInAssetUnits = ethers.parseUnits(
          depositQuantityInDecimal,
          quoteAssetDecimals,
        );
        const composeMessage = ethers.solidityPacked(
          ['uint64', 'uint32', 'uint256', 'bytes'],
          [
            0,
            1,
            depositQuantityInAssetUnits,
            ethers.solidityPacked(
              ['bytes', 'bytes'],
              [
                ethers.AbiCoder.defaultAbiCoder().encode(
                  ['address'],
                  [traderWallet.address],
                ),
                ethers.AbiCoder.defaultAbiCoder().encode(
                  ['address'],
                  [traderWallet.address],
                ),
              ],
            ),
          ],
        );

        const bridgeAdapter = await ExchangeStargateV2AdapterFactory.deploy(
          await custodian.getAddress(),
          decimalToPips('0.99900000'),
          await stargatePoolMock.getAddress(),
          await stargatePoolMock.getAddress(),
          await usdc.getAddress(),
        );
        await bridgeAdapter.setDepositEnabled(true);

        await usdc.transfer(
          await bridgeAdapter.getAddress(),
          depositQuantityInAssetUnits,
        );

        await stargatePoolMock.lzCompose(
          await bridgeAdapter.getAddress(),
          await stargatePoolMock.getAddress(),
          ethers.randomBytes(32),
          composeMessage,
          await stargatePoolMock.getAddress(),
          '0x',
        );

        const composeFailedEvents = await bridgeAdapter.queryFilter(
          bridgeAdapter.filters.LzComposeFailed(),
        );
        expect(composeFailedEvents).to.have.lengthOf(0);

        const depositedEvents = await exchange.queryFilter(
          exchange.filters.Deposited(),
        );

        expect(depositedEvents).to.have.lengthOf(1);
        expect(depositedEvents[0].args?.index).to.equal(1);
        expect(depositedEvents[0].args?.quantity).to.equal(
          decimalToPips(depositQuantityInDecimal),
        );
      });

      it('should return tokens to destination wallet when deposits are disabled in adapter', async () => {
        const depositQuantityInDecimal = '5.00000000';
        const depositQuantityInAssetUnits = ethers.parseUnits(
          depositQuantityInDecimal,
          quoteAssetDecimals,
        );
        const composeMessage = ethers.solidityPacked(
          ['uint64', 'uint32', 'uint256', 'bytes'],
          [
            0,
            1,
            depositQuantityInAssetUnits,
            ethers.solidityPacked(
              ['bytes', 'bytes'],
              [
                ethers.AbiCoder.defaultAbiCoder().encode(
                  ['address'],
                  [traderWallet.address],
                ),
                ethers.AbiCoder.defaultAbiCoder().encode(
                  ['address'],
                  [traderWallet.address],
                ),
              ],
            ),
          ],
        );

        const bridgeAdapter = await ExchangeStargateV2AdapterFactory.deploy(
          await custodian.getAddress(),
          decimalToPips('0.99900000'),
          await stargatePoolMock.getAddress(),
          await stargatePoolMock.getAddress(),
          await usdc.getAddress(),
        );

        await usdc.transfer(
          await bridgeAdapter.getAddress(),
          depositQuantityInAssetUnits,
        );

        await stargatePoolMock.lzCompose(
          await bridgeAdapter.getAddress(),
          await stargatePoolMock.getAddress(),
          ethers.randomBytes(32),
          composeMessage,
          await stargatePoolMock.getAddress(),
          '0x',
        );

        const composeFailedEvents = await bridgeAdapter.queryFilter(
          bridgeAdapter.filters.LzComposeFailed(),
        );
        expect(composeFailedEvents).to.have.lengthOf(1);
        expect(composeFailedEvents[0].args?.destinationWallet).to.equal(
          traderWallet.address,
        );
        expect(composeFailedEvents[0].args?.quantity).to.equal(
          depositQuantityInAssetUnits,
        );
        expect(
          ethers.toUtf8String(composeFailedEvents[0].args?.errorData),
        ).to.match(/deposits disabled/i);

        const transferEvents = await usdc.queryFilter(usdc.filters.Transfer());
        const lastTransferEvent = transferEvents[transferEvents.length - 1];
        expect(lastTransferEvent.args?.from).to.equal(
          await bridgeAdapter.getAddress(),
        );
        expect(lastTransferEvent.args?.to).to.equal(traderWallet.address);
        expect(lastTransferEvent.args?.value).to.equal(
          depositQuantityInAssetUnits,
        );

        await expect(usdc.balanceOf(bridgeAdapter)).to.eventually.equal(
          BigInt(0),
        );
      });

      it('should return tokens to destination wallet when deposits are disabled in Exchange', async () => {
        const depositQuantityInDecimal = '5.00000000';
        const depositQuantityInAssetUnits = ethers.parseUnits(
          depositQuantityInDecimal,
          quoteAssetDecimals,
        );
        const composeMessage = ethers.solidityPacked(
          ['uint64', 'uint32', 'uint256', 'bytes'],
          [
            0,
            1,
            depositQuantityInAssetUnits,
            ethers.solidityPacked(
              ['bytes', 'bytes'],
              [
                ethers.AbiCoder.defaultAbiCoder().encode(
                  ['address'],
                  [traderWallet.address],
                ),
                ethers.AbiCoder.defaultAbiCoder().encode(
                  ['address'],
                  [traderWallet.address],
                ),
              ],
            ),
          ],
        );

        const bridgeAdapter = await ExchangeStargateV2AdapterFactory.deploy(
          await custodian.getAddress(),
          decimalToPips('0.99900000'),
          await stargatePoolMock.getAddress(),
          await stargatePoolMock.getAddress(),
          await usdc.getAddress(),
        );
        await bridgeAdapter.setDepositEnabled(true);

        await exchange.setDepositEnabled(false);

        await usdc.transfer(
          await bridgeAdapter.getAddress(),
          depositQuantityInAssetUnits,
        );

        await stargatePoolMock.lzCompose(
          await bridgeAdapter.getAddress(),
          await stargatePoolMock.getAddress(),
          ethers.randomBytes(32),
          composeMessage,
          await stargatePoolMock.getAddress(),
          '0x',
        );

        const composeFailedEvents = await bridgeAdapter.queryFilter(
          bridgeAdapter.filters.LzComposeFailed(),
        );
        expect(composeFailedEvents).to.have.lengthOf(1);
        expect(composeFailedEvents[0].args?.destinationWallet).to.equal(
          traderWallet.address,
        );
        expect(composeFailedEvents[0].args?.quantity).to.equal(
          depositQuantityInAssetUnits,
        );

        const transferEvents = await usdc.queryFilter(usdc.filters.Transfer());
        const lastTransferEvent = transferEvents[transferEvents.length - 1];
        expect(lastTransferEvent.args?.from).to.equal(
          await bridgeAdapter.getAddress(),
        );
        expect(lastTransferEvent.args?.to).to.equal(traderWallet.address);
        expect(lastTransferEvent.args?.value).to.equal(
          depositQuantityInAssetUnits,
        );

        await expect(usdc.balanceOf(bridgeAdapter)).to.eventually.equal(
          BigInt(0),
        );
      });
    });
  });

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
        ).to.eventually.be.rejectedWith(/invalid router address/i);
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
          .withdraw(
            ...getWithdrawArguments(withdrawal, '0.00000000', signature),
          );
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
          .withdraw(
            ...getWithdrawArguments(withdrawal, '0.00000000', signature),
          );
      });

      it('should work with fallback for valid arguments when adapter is not funded', async () => {
        await exchange
          .connect(dispatcherWallet)
          .withdraw(
            ...getWithdrawArguments(withdrawal, '0.00000000', signature),
          );
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
            .withdrawNativeAsset(
              traderWallet.address,
              ethers.parseEther('1.0'),
            ),
        ).to.eventually.be.rejectedWith(/caller must be admin/i);
      });
    });
  });
});
