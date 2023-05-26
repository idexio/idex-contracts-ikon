import { ethers, network } from 'hardhat';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

import {
  baseAssetSymbol,
  buildIndexPrice,
  buildIndexPriceWithTimestamp,
  buildIndexPriceWithValue,
  deployContractsExceptCustodian,
  expect,
  getLatestBlockTimestampInSeconds,
} from './helpers';
import {
  hardhatChainId,
  getDomainSeparator,
  indexPriceToArgumentStruct,
  decimalToPips,
} from '../lib';
import {
  ExchangeIndexPriceAdapterMock,
  ExchangeIndexPriceAdapterMock__factory,
  Exchange_v4,
  IDEXIndexPriceAdapter,
  IDEXIndexPriceAdapter__factory,
} from '../typechain-types';

describe('IDEXIndexPriceAdapter', function () {
  let ExchangeIndexPriceAdapterMockFactory: ExchangeIndexPriceAdapterMock__factory;
  let IDEXIndexPriceAdapterFactory: IDEXIndexPriceAdapter__factory;
  let indexPriceServiceWallet: SignerWithAddress;
  let owner: SignerWithAddress;

  before(async () => {
    await network.provider.send('hardhat_reset');
    ExchangeIndexPriceAdapterMockFactory = await ethers.getContractFactory(
      'ExchangeIndexPriceAdapterMock',
    );
    IDEXIndexPriceAdapterFactory = await ethers.getContractFactory(
      'IDEXIndexPriceAdapter',
    );
    indexPriceServiceWallet = (await ethers.getSigners())[5];
    [owner] = await ethers.getSigners();
  });

  describe('deploy', async function () {
    it('should work for valid activator and IPS wallet', async () => {
      await IDEXIndexPriceAdapterFactory.deploy(owner.address, [
        indexPriceServiceWallet.address,
      ]);
    });

    it('should revert for invalid activator', async () => {
      await expect(
        IDEXIndexPriceAdapterFactory.deploy(ethers.constants.AddressZero, [
          indexPriceServiceWallet.address,
        ]),
      ).to.eventually.be.rejectedWith(/invalid IPS wallet/i);
    });

    it('should revert for invalid IPS wallet', async () => {
      await expect(
        IDEXIndexPriceAdapterFactory.deploy(owner.address, [
          ethers.constants.AddressZero,
        ]),
      ).to.eventually.be.rejectedWith(/invalid IPS wallet/i);
    });
  });

  describe('setActive', async function () {
    let exchange: Exchange_v4;
    let indexPriceAdapter: IDEXIndexPriceAdapter;
    let oldIndexPriceAdapter: IDEXIndexPriceAdapter;

    beforeEach(async () => {
      const results = await deployContractsExceptCustodian(owner);
      exchange = results.exchange;
      oldIndexPriceAdapter = results.indexPriceAdapter;

      indexPriceAdapter = await IDEXIndexPriceAdapterFactory.deploy(
        owner.address,
        [indexPriceServiceWallet.address],
      );
    });

    it('should work for valid contract address', async () => {
      await indexPriceAdapter.setActive(exchange.address);

      await expect(
        indexPriceAdapter.exchangeDomainSeparator(),
      ).to.eventually.equal(
        ethers.utils._TypedDataEncoder.hashDomain(
          getDomainSeparator(exchange.address, hardhatChainId),
        ),
      );
    });

    it('should migrate latest prices', async () => {
      await exchange.setDispatcher(owner.address);
      await exchange.addMarket({
        exists: true,
        isActive: false,
        baseAssetSymbol,
        indexPriceAtDeactivation: 0,
        lastIndexPrice: 0,
        lastIndexPriceTimestampInMs: 0,
        overridableFields: {
          initialMarginFraction: '5000000',
          maintenanceMarginFraction: '3000000',
          incrementalInitialMarginFraction: '1000000',
          baselinePositionSize: '14000000000',
          incrementalPositionSize: '2800000000',
          maximumPositionSize: '282000000000',
          minimumPositionSize: '10000000',
        },
      });
      await exchange.connect(owner).activateMarket(baseAssetSymbol);
      await exchange
        .connect(owner)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            oldIndexPriceAdapter.address,
            await buildIndexPriceWithValue(
              exchange.address,
              owner,
              '1900.00000000',
            ),
          ),
        ]);

      await expect(
        indexPriceAdapter.loadPriceForBaseAssetSymbol(baseAssetSymbol),
      ).to.eventually.be.rejectedWith(/missing price/i);

      await indexPriceAdapter.setActive(exchange.address);

      expect(
        (
          await indexPriceAdapter.loadPriceForBaseAssetSymbol(baseAssetSymbol)
        ).toString(),
      ).to.equal(decimalToPips('1900.00000000'));
    });

    it('should revert for invalid exchange address', async () => {
      await expect(
        indexPriceAdapter.setActive(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/invalid exchange contract address/i);
    });

    it('should work when called twice', async () => {
      await indexPriceAdapter.setActive(exchange.address);
      await indexPriceAdapter.setActive(exchange.address);
    });

    it('should revert when called not called by activator', async () => {
      await indexPriceAdapter.setActive(exchange.address);

      await expect(
        indexPriceAdapter
          .connect((await ethers.getSigners())[1])
          .setActive(exchange.address),
      ).to.eventually.be.rejectedWith(/caller must be activator/i);
    });
  });

  describe('loadPriceForBaseAssetSymbol', async function () {
    let exchangeMock: ExchangeIndexPriceAdapterMock;
    let indexPriceAdapter: IDEXIndexPriceAdapter;

    beforeEach(async () => {
      indexPriceAdapter = await IDEXIndexPriceAdapterFactory.deploy(
        owner.address,
        [indexPriceServiceWallet.address],
      );
      exchangeMock = await ExchangeIndexPriceAdapterMockFactory.deploy(
        indexPriceAdapter.address,
      );
      await indexPriceAdapter.setActive(exchangeMock.address);
    });

    it('should work when price is in storage', async () => {
      const indexPrice = await buildIndexPrice(
        exchangeMock.address,
        indexPriceServiceWallet,
      );

      await exchangeMock.validateIndexPricePayload(
        indexPriceToArgumentStruct(indexPriceAdapter.address, indexPrice)
          .payload,
      );

      const price = (
        await indexPriceAdapter.loadPriceForBaseAssetSymbol(baseAssetSymbol)
      ).toString();
      expect(price).to.equal(decimalToPips(indexPrice.price));
    });

    it('should not store outdated price', async () => {
      const indexPrice = await buildIndexPrice(
        exchangeMock.address,
        indexPriceServiceWallet,
      );

      await exchangeMock.validateIndexPricePayload(
        indexPriceToArgumentStruct(indexPriceAdapter.address, indexPrice)
          .payload,
      );

      const indexPrice2 = await buildIndexPriceWithTimestamp(
        exchangeMock.address,
        indexPriceServiceWallet,
        (await getLatestBlockTimestampInSeconds()) * 1000 - 10000,
        baseAssetSymbol,
        '1234.67890000',
      );
      await exchangeMock.validateIndexPricePayload(
        indexPriceToArgumentStruct(indexPriceAdapter.address, indexPrice2)
          .payload,
      );

      const price = (
        await indexPriceAdapter.loadPriceForBaseAssetSymbol(baseAssetSymbol)
      ).toString();
      expect(price).to.equal(decimalToPips(indexPrice.price));
    });

    it('should revert for missing price', async () => {
      await expect(
        indexPriceAdapter.loadPriceForBaseAssetSymbol(baseAssetSymbol),
      ).to.eventually.be.rejectedWith(/missing price/i);
    });
  });

  describe('validateIndexPricePayload', async function () {
    let indexPriceAdapter: IDEXIndexPriceAdapter;

    beforeEach(async () => {
      indexPriceAdapter = await IDEXIndexPriceAdapterFactory.deploy(
        owner.address,
        [indexPriceServiceWallet.address],
      );
    });

    it('should revert when not called by exchange', async () => {
      await expect(
        indexPriceAdapter.validateIndexPricePayload('0x00'),
      ).to.eventually.be.rejectedWith(/exchange not set/i);

      const exchange = (await deployContractsExceptCustodian(owner)).exchange;
      await indexPriceAdapter.setActive(exchange.address);
      await expect(
        indexPriceAdapter.validateIndexPricePayload('0x00'),
      ).to.eventually.be.rejectedWith(/caller must be exchange/i);
    });
  });
});
