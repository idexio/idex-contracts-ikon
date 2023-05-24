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
  IDEXIndexAndOraclePriceAdapter,
  IDEXIndexAndOraclePriceAdapter__factory,
} from '../typechain-types';

describe('IDEXIndexAndOraclePriceAdapter', function () {
  let ExchangeIndexPriceAdapterMockFactory: ExchangeIndexPriceAdapterMock__factory;
  let IDEXIndexAndOraclePriceAdapterFactory: IDEXIndexAndOraclePriceAdapter__factory;
  let indexPriceServiceWallet: SignerWithAddress;
  let owner: SignerWithAddress;

  before(async () => {
    await network.provider.send('hardhat_reset');
    ExchangeIndexPriceAdapterMockFactory = await ethers.getContractFactory(
      'ExchangeIndexPriceAdapterMock',
    );
    IDEXIndexAndOraclePriceAdapterFactory = await ethers.getContractFactory(
      'IDEXIndexAndOraclePriceAdapter',
    );
    indexPriceServiceWallet = (await ethers.getSigners())[5];
    [owner] = await ethers.getSigners();
  });

  describe('deploy', async function () {
    it('should work for valid activator and IPS wallet', async () => {
      await IDEXIndexAndOraclePriceAdapterFactory.deploy(owner.address, [
        indexPriceServiceWallet.address,
      ]);
    });

    it('should revert for invalid activator', async () => {
      await expect(
        IDEXIndexAndOraclePriceAdapterFactory.deploy(
          ethers.constants.AddressZero,
          [indexPriceServiceWallet.address],
        ),
      ).to.eventually.be.rejectedWith(/invalid IPS wallet/i);
    });

    it('should revert for invalid IPS wallet', async () => {
      await expect(
        IDEXIndexAndOraclePriceAdapterFactory.deploy(owner.address, [
          ethers.constants.AddressZero,
        ]),
      ).to.eventually.be.rejectedWith(/invalid IPS wallet/i);
    });
  });

  describe('setActive', async function () {
    let exchange: Exchange_v4;
    let indexPriceAdapter: IDEXIndexAndOraclePriceAdapter;
    let oldIndexPriceAdapter: IDEXIndexAndOraclePriceAdapter;

    beforeEach(async () => {
      const results = await deployContractsExceptCustodian(owner);
      exchange = results.exchange;
      oldIndexPriceAdapter = results.indexPriceAdapter;

      indexPriceAdapter = await IDEXIndexAndOraclePriceAdapterFactory.deploy(
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
    let indexPriceAdapter: IDEXIndexAndOraclePriceAdapter;

    beforeEach(async () => {
      indexPriceAdapter = await IDEXIndexAndOraclePriceAdapterFactory.deploy(
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
    let indexPriceAdapter: IDEXIndexAndOraclePriceAdapter;

    beforeEach(async () => {
      indexPriceAdapter = await IDEXIndexAndOraclePriceAdapterFactory.deploy(
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

  describe('validateInitialIndexPricePayloadAdmin', async function () {
    let exchange: Exchange_v4;
    let indexPriceAdapter: IDEXIndexAndOraclePriceAdapter;

    beforeEach(async () => {
      indexPriceAdapter = await IDEXIndexAndOraclePriceAdapterFactory.deploy(
        owner.address,
        [indexPriceServiceWallet.address],
      );
      exchange = (
        await deployContractsExceptCustodian(
          owner,
          owner,
          owner,
          indexPriceServiceWallet,
        )
      ).exchange;
    });

    it('should work when no price yet exists', async () => {
      await indexPriceAdapter.setActive(exchange.address);

      await expect(
        indexPriceAdapter.loadPriceForBaseAssetSymbol(baseAssetSymbol),
      ).to.eventually.be.rejectedWith(/missing price/i);

      await indexPriceAdapter.validateInitialIndexPricePayloadAdmin(
        indexPriceToArgumentStruct(
          indexPriceAdapter.address,
          await buildIndexPriceWithValue(
            exchange.address,
            indexPriceServiceWallet,
            '1900.00000000',
          ),
        ).payload,
      );

      expect(
        (
          await indexPriceAdapter.loadPriceForBaseAssetSymbol(baseAssetSymbol)
        ).toString(),
      ).to.equal(decimalToPips('1900.00000000'));
    });

    it('should revert when not sent by admin', async () => {
      await expect(
        indexPriceAdapter
          .connect((await ethers.getSigners())[8])
          .validateInitialIndexPricePayloadAdmin(
            indexPriceToArgumentStruct(
              indexPriceAdapter.address,
              await buildIndexPriceWithValue(
                exchange.address,
                indexPriceServiceWallet,
                '1900.00000000',
              ),
            ).payload,
          ),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });

    it('should revert when exchange is not set', async () => {
      await expect(
        indexPriceAdapter.validateInitialIndexPricePayloadAdmin(
          indexPriceToArgumentStruct(
            indexPriceAdapter.address,
            await buildIndexPriceWithValue(
              exchange.address,
              indexPriceServiceWallet,
              '1900.00000000',
            ),
          ).payload,
        ),
      ).to.eventually.be.rejectedWith(/exchange not set/i);
    });

    it('should revert when price already exists', async () => {
      await indexPriceAdapter.setActive(exchange.address);

      await indexPriceAdapter.validateInitialIndexPricePayloadAdmin(
        indexPriceToArgumentStruct(
          indexPriceAdapter.address,
          await buildIndexPriceWithValue(
            exchange.address,
            indexPriceServiceWallet,
            '1900.00000000',
          ),
        ).payload,
      );

      await expect(
        indexPriceAdapter.validateInitialIndexPricePayloadAdmin(
          indexPriceToArgumentStruct(
            indexPriceAdapter.address,
            await buildIndexPriceWithValue(
              exchange.address,
              indexPriceServiceWallet,
              '1900.00000000',
            ),
          ).payload,
        ),
      ).to.eventually.be.rejectedWith(/price already exists for market/i);
    });
  });
});
