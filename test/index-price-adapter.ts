import { ethers, network } from 'hardhat';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

import {
  baseAssetSymbol,
  buildIndexPrice,
  buildIndexPriceWithTimestamp,
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

  before(async () => {
    await network.provider.send('hardhat_reset');
    ExchangeIndexPriceAdapterMockFactory = await ethers.getContractFactory(
      'ExchangeIndexPriceAdapterMock',
    );
    IDEXIndexPriceAdapterFactory = await ethers.getContractFactory(
      'IDEXIndexPriceAdapter',
    );
    indexPriceServiceWallet = (await ethers.getSigners())[5];
  });

  describe('deploy', async function () {
    it('should work for valid wallet', async () => {
      await IDEXIndexPriceAdapterFactory.deploy([
        indexPriceServiceWallet.address,
      ]);
    });

    it('should revert for invalid wallet', async () => {
      await expect(
        IDEXIndexPriceAdapterFactory.deploy([ethers.constants.AddressZero]),
      ).to.eventually.be.rejectedWith(/invalid IPS wallet/i);
    });
  });

  describe('setExchange', async function () {
    let exchange: Exchange_v4;
    let indexPriceAdapter: IDEXIndexPriceAdapter;

    beforeEach(async () => {
      const [owner] = await ethers.getSigners();
      exchange = (await deployContractsExceptCustodian(owner)).exchange;
      indexPriceAdapter = await IDEXIndexPriceAdapterFactory.deploy([
        indexPriceServiceWallet.address,
      ]);
    });

    it('should work for valid contract address', async () => {
      await indexPriceAdapter.setExchange(exchange.address);

      await expect(
        indexPriceAdapter.exchangeDomainSeparator(),
      ).to.eventually.equal(
        ethers.utils._TypedDataEncoder.hashDomain(
          getDomainSeparator(exchange.address, hardhatChainId),
        ),
      );
    });

    it('should revert for invalid exchange address', async () => {
      await expect(
        indexPriceAdapter.setExchange(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/invalid exchange contract address/i);
    });

    it('should revert when called twice', async () => {
      await indexPriceAdapter.setExchange(exchange.address);

      await expect(
        indexPriceAdapter.setExchange(exchange.address),
      ).to.eventually.be.rejectedWith(
        /exchange contract can only be set once/i,
      );
    });

    it('should revert when called not called by owner', async () => {
      await indexPriceAdapter.setExchange(exchange.address);

      await expect(
        indexPriceAdapter
          .connect((await ethers.getSigners())[1])
          .setExchange(exchange.address),
      ).to.eventually.be.rejectedWith(/caller must be owner/i);
    });
  });

  describe('loadPriceForBaseAssetSymbol', async function () {
    let exchangeMock: ExchangeIndexPriceAdapterMock;
    let indexPriceAdapter: IDEXIndexPriceAdapter;

    beforeEach(async () => {
      indexPriceAdapter = await IDEXIndexPriceAdapterFactory.deploy([
        indexPriceServiceWallet.address,
      ]);
      exchangeMock = await ExchangeIndexPriceAdapterMockFactory.deploy(
        indexPriceAdapter.address,
      );
      await indexPriceAdapter.setExchange(exchangeMock.address);
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
      indexPriceAdapter = await IDEXIndexPriceAdapterFactory.deploy([
        indexPriceServiceWallet.address,
      ]);
    });

    it('should revert when not called by exchange', async () => {
      await expect(
        indexPriceAdapter.validateIndexPricePayload('0x00'),
      ).to.eventually.be.rejectedWith(/caller must be exchange/i);
    });
  });
});
