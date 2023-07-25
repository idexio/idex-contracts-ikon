import BigNumber from 'bignumber.js';
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
  quoteAssetSymbol,
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
  PythIndexPriceAdapter,
  PythIndexPriceAdapter__factory,
  PythMock,
  PythMock__factory,
  StorkVerifierMock,
  StorkVerifierMock__factory,
  StorkIndexAndOraclePriceAdapter,
  StorkIndexAndOraclePriceAdapter__factory,
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
      ).to.eventually.be.rejectedWith(/invalid activator/i);
    });

    it('should revert for missing IPS wallets', async () => {
      await expect(
        IDEXIndexAndOraclePriceAdapterFactory.deploy(owner.address, []),
      ).to.eventually.be.rejectedWith(/missing IPS wallets/i);
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

    it('should revert when price is zero', async () => {
      const exchangeMock = await ExchangeIndexPriceAdapterMockFactory.deploy(
        indexPriceAdapter.address,
      );
      await indexPriceAdapter.setActive(exchangeMock.address);

      await expect(
        exchangeMock.validateIndexPricePayload(
          indexPriceToArgumentStruct(
            indexPriceAdapter.address,
            await buildIndexPriceWithTimestamp(
              exchangeMock.address,
              indexPriceServiceWallet,
              (await getLatestBlockTimestampInSeconds()) * 1000 - 10000,
              baseAssetSymbol,
              '0.00000000',
            ),
          ).payload,
        ),
      ).to.eventually.be.rejectedWith(/unexpected non-positive price/i);
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

    it('should revert when price is zero', async () => {
      const exchangeMock = await ExchangeIndexPriceAdapterMockFactory.deploy(
        indexPriceAdapter.address,
      );
      await indexPriceAdapter.setActive(exchangeMock.address);

      await expect(
        indexPriceAdapter.validateInitialIndexPricePayloadAdmin(
          indexPriceToArgumentStruct(
            indexPriceAdapter.address,
            await buildIndexPriceWithTimestamp(
              exchangeMock.address,
              indexPriceServiceWallet,
              (await getLatestBlockTimestampInSeconds()) * 1000 - 10000,
              baseAssetSymbol,
              '0.00000000',
            ),
          ).payload,
        ),
      ).to.eventually.be.rejectedWith(/unexpected non-positive price/i);
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

describe('PythIndexPriceAdapter', function () {
  let ownerWallet: SignerWithAddress;
  let pyth: PythMock;
  let PythMockFactory: PythMock__factory;
  let PythIndexPriceAdapterFactory: PythIndexPriceAdapter__factory;

  const oneDayInSeconds = 1 * 24 * 60 * 60;

  before(async () => {
    await network.provider.send('hardhat_reset');
    [PythMockFactory, PythIndexPriceAdapterFactory] = await Promise.all([
      ethers.getContractFactory('PythMock'),
      ethers.getContractFactory('PythIndexPriceAdapter'),
    ]);

    ownerWallet = (await ethers.getSigners())[0];
  });

  beforeEach(async () => {
    pyth = await PythMockFactory.deploy(oneDayInSeconds, 1);
  });

  describe('deploy', async function () {
    it('should work for valid arguments', async () => {
      await PythIndexPriceAdapterFactory.deploy(
        ownerWallet.address,
        [baseAssetSymbol],
        [ethers.utils.randomBytes(32)],
        pyth.address,
      );
    });

    it('should revert for invalid activator', async () => {
      await expect(
        PythIndexPriceAdapterFactory.deploy(
          ethers.constants.AddressZero,
          [baseAssetSymbol],
          [ethers.utils.randomBytes(32)],
          pyth.address,
        ),
      ).to.eventually.be.rejectedWith(/invalid activator/i);
    });

    it('should revert for invalid Pyth contract', async () => {
      await expect(
        PythIndexPriceAdapterFactory.deploy(
          ownerWallet.address,
          [baseAssetSymbol],
          [ethers.utils.randomBytes(32)],
          ethers.constants.AddressZero,
        ),
      ).to.eventually.be.rejectedWith(/invalid pyth contract address/i);
    });

    it('should revert for mismatched argument lengths', async () => {
      await expect(
        PythIndexPriceAdapterFactory.deploy(
          ownerWallet.address,
          [baseAssetSymbol, baseAssetSymbol],
          [ethers.utils.randomBytes(32)],
          pyth.address,
        ),
      ).to.eventually.be.rejectedWith(/argument length mismatch/i);

      await expect(
        PythIndexPriceAdapterFactory.deploy(
          ownerWallet.address,
          [baseAssetSymbol],
          [ethers.utils.randomBytes(32), ethers.utils.randomBytes(32)],
          pyth.address,
        ),
      ).to.eventually.be.rejectedWith(/argument length mismatch/i);
    });

    it('should revert for invalid base asset symbol', async () => {
      await expect(
        PythIndexPriceAdapterFactory.deploy(
          ownerWallet.address,
          [''],
          [ethers.utils.randomBytes(32)],
          pyth.address,
        ),
      ).to.eventually.be.rejectedWith(/invalid base asset symbol/i);
    });

    it('should revert for invalid price ID', async () => {
      await expect(
        PythIndexPriceAdapterFactory.deploy(
          ownerWallet.address,
          [baseAssetSymbol],
          [
            '0x0000000000000000000000000000000000000000000000000000000000000000',
          ],
          pyth.address,
        ),
      ).to.eventually.be.rejectedWith(/invalid price id/i);
    });
  });

  describe('addBaseAssetSymbolAndPriceId', async function () {
    let adapter: PythIndexPriceAdapter;
    const priceId = ethers.utils.randomBytes(32);

    beforeEach(async () => {
      adapter = await PythIndexPriceAdapterFactory.deploy(
        ownerWallet.address,
        [baseAssetSymbol],
        [priceId],
        pyth.address,
      );
    });

    it('should work for valid base asset symbol and price ID', async () => {
      await adapter.addBaseAssetSymbolAndPriceId(
        'XYZ',
        ethers.utils.randomBytes(32),
      );
    });

    it('should revert when not sent by admin', async () => {
      await expect(
        adapter
          .connect((await ethers.getSigners())[5])
          .addBaseAssetSymbolAndPriceId('XYZ', ethers.utils.randomBytes(32)),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });

    it('should revert for invalid base asset symbol', async () => {
      await expect(
        adapter.addBaseAssetSymbolAndPriceId('', ethers.utils.randomBytes(32)),
      ).to.eventually.be.rejectedWith(/invalid base asset symbol/i);
    });

    it('should revert for invalid price ID', async () => {
      await expect(
        adapter.addBaseAssetSymbolAndPriceId(
          'XYZ',
          '0x0000000000000000000000000000000000000000000000000000000000000000',
        ),
      ).to.eventually.be.rejectedWith(/invalid price id/i);
    });

    it('should revert for already added base asset symbol', async () => {
      await expect(
        adapter.addBaseAssetSymbolAndPriceId(
          baseAssetSymbol,
          ethers.utils.randomBytes(32),
        ),
      ).to.eventually.be.rejectedWith(/already added base asset symbol/i);
    });

    it('should revert for already added price ID', async () => {
      await expect(
        adapter.addBaseAssetSymbolAndPriceId('XYZ', priceId),
      ).to.eventually.be.rejectedWith(/already added price ID/i);
    });
  });

  describe('setActive', async function () {
    let adapter: PythIndexPriceAdapter;
    let exchange: Exchange_v4;
    const priceId = ethers.utils.randomBytes(32);

    beforeEach(async () => {
      adapter = await PythIndexPriceAdapterFactory.deploy(
        ownerWallet.address,
        [baseAssetSymbol],
        [priceId],
        pyth.address,
      );
      const results = await deployContractsExceptCustodian(
        (
          await ethers.getSigners()
        )[0],
      );
      exchange = results.exchange;
    });

    it('should work', async () => {
      await adapter.setActive(exchange.address);

      await expect(adapter.exchange()).to.eventually.equal(exchange.address);
    });

    it('should revert when not called by activator', async () => {
      await expect(
        adapter
          .connect((await ethers.getSigners())[10])
          .setActive(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/caller must be activator/i);
    });

    it('should revert for non-contract address', async () => {
      await expect(
        adapter.setActive(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/invalid exchange contract address/i);
    });

    it('should revert if called twice', async () => {
      await adapter.setActive(exchange.address);

      await expect(
        adapter.setActive(exchange.address),
      ).to.eventually.be.rejectedWith(/adapter already active/i);
    });
  });

  describe('validateIndexPricePayload', async function () {
    let adapter: PythIndexPriceAdapter;
    let exchange: ExchangeIndexPriceAdapterMock;
    let ExchangeIndexPriceAdapterMockFactory: ExchangeIndexPriceAdapterMock__factory;
    const priceId = ethers.utils.randomBytes(32);

    before(async () => {
      ExchangeIndexPriceAdapterMockFactory = await ethers.getContractFactory(
        'ExchangeIndexPriceAdapterMock',
      );
    });

    beforeEach(async () => {
      adapter = await PythIndexPriceAdapterFactory.deploy(
        ownerWallet.address,
        [baseAssetSymbol],
        [priceId],
        pyth.address,
      );
      exchange = await ExchangeIndexPriceAdapterMockFactory.deploy(
        adapter.address,
      );
    });

    it('should work for valid payload with funding with 8 decimals', async () => {
      await adapter.setActive(exchange.address);

      await ownerWallet.sendTransaction({
        to: adapter.address,
        value: ethers.utils.parseEther('1.0'),
      });

      await exchange.validateIndexPricePayload(
        await buildPythPricePayload(priceId, decimalToPips('2000.00000000'), 8),
      );

      const events = await exchange.queryFilter(
        exchange.filters.ValidatedIndexPrice(),
      );
      expect(events).to.have.lengthOf(1);
      expect(events[0].args?.indexPrice.price).to.equal(
        decimalToPips('2000.00000000'),
      );
    });

    it('should work for valid payload with funding with 6 decimals', async () => {
      await adapter.setActive(exchange.address);

      await ownerWallet.sendTransaction({
        to: adapter.address,
        value: ethers.utils.parseEther('1.0'),
      });

      await exchange.validateIndexPricePayload(
        await buildPythPricePayload(priceId, decimalToPips('2000.00000000'), 6),
      );

      const events = await exchange.queryFilter(
        exchange.filters.ValidatedIndexPrice(),
      );
      expect(events).to.have.lengthOf(1);
      expect(events[0].args?.indexPrice.price).to.equal(
        decimalToPips('200000.00000000'),
      );
    });

    it('should work for valid payload with funding with 10 decimals', async () => {
      await adapter.setActive(exchange.address);

      await ownerWallet.sendTransaction({
        to: adapter.address,
        value: ethers.utils.parseEther('1.0'),
      });

      await exchange.validateIndexPricePayload(
        await buildPythPricePayload(
          priceId,
          decimalToPips('2000.00000000'),
          10,
        ),
      );

      const events = await exchange.queryFilter(
        exchange.filters.ValidatedIndexPrice(),
      );
      expect(events).to.have.lengthOf(1);
      expect(events[0].args?.indexPrice.price).to.equal(
        decimalToPips('20.00000000'),
      );
    });

    it('should revert for invalid price ID', async () => {
      await adapter.setActive(exchange.address);

      await ownerWallet.sendTransaction({
        to: adapter.address,
        value: ethers.utils.parseEther('1.0'),
      });

      await expect(
        exchange.validateIndexPricePayload(
          await buildPythPricePayload(
            ethers.utils.randomBytes(32),
            decimalToPips('2000.00000000'),
          ),
        ),
      ).to.eventually.be.rejectedWith(/unknown price id/i);
    });

    it('should revert for zero price', async () => {
      await adapter.setActive(exchange.address);

      await ownerWallet.sendTransaction({
        to: adapter.address,
        value: ethers.utils.parseEther('1.0'),
      });

      await expect(
        exchange.validateIndexPricePayload(
          await buildPythPricePayload(priceId, decimalToPips('0.00000000')),
        ),
      ).to.eventually.be.rejectedWith(/unexpected non-positive price/i);
    });

    it('should revert for zero price after pip conversion', async () => {
      await adapter.setActive(exchange.address);

      await ownerWallet.sendTransaction({
        to: adapter.address,
        value: ethers.utils.parseEther('1.0'),
      });

      await expect(
        exchange.validateIndexPricePayload(
          await buildPythPricePayload(priceId, decimalToPips('0.00000001'), 20),
        ),
      ).to.eventually.be.rejectedWith(/unexpected non-positive price/i);
    });

    it('should revert for negative price', async () => {
      await adapter.setActive(exchange.address);

      await ownerWallet.sendTransaction({
        to: adapter.address,
        value: ethers.utils.parseEther('1.0'),
      });

      await expect(
        exchange.validateIndexPricePayload(
          await buildPythPricePayload(priceId, decimalToPips('-2000.00000000')),
        ),
      ).to.eventually.be.rejectedWith(/unexpected non-positive price/i);
    });

    it('should revert when balance is insufficient for fee', async () => {
      await adapter.setActive(exchange.address);

      await expect(
        exchange.validateIndexPricePayload(
          await buildPythPricePayload(priceId, decimalToPips('2000.00000000')),
        ),
      ).to.eventually.be.rejectedWith(/insufficient balance for update fee/i);
    });

    it('should revert Exchange is not set', async () => {
      await expect(
        adapter.validateIndexPricePayload(
          await buildPythPricePayload(priceId, decimalToPips('2000.00000000')),
        ),
      ).to.eventually.be.rejectedWith(/caller must be exchange contract/i);
    });

    it('should revert when caller is not Exchange', async () => {
      await adapter.setActive(adapter.address);

      await expect(
        adapter.validateIndexPricePayload(
          await buildPythPricePayload(priceId, decimalToPips('2000.00000000')),
        ),
      ).to.eventually.be.rejectedWith(/caller must be exchange contract/i);
    });
  });

  describe('withdrawNativeAsset', async function () {
    let adapter: PythIndexPriceAdapter;
    let destinationWallet: SignerWithAddress;
    const priceId = ethers.utils.randomBytes(32);

    beforeEach(async () => {
      adapter = await PythIndexPriceAdapterFactory.deploy(
        ownerWallet.address,
        [baseAssetSymbol],
        [priceId],
        pyth.address,
      );
      destinationWallet = (await ethers.getSigners())[1];

      await ownerWallet.sendTransaction({
        to: adapter.address,
        value: ethers.utils.parseEther('1.0'),
      });
    });

    it('should work when caller is admin', async () => {
      await adapter.withdrawNativeAsset(
        destinationWallet.address,
        ethers.utils.parseEther('1.0'),
      );
    });

    it('should revert when caller is not admin', async () => {
      await expect(
        adapter
          .connect((await ethers.getSigners())[10])
          .withdrawNativeAsset(
            destinationWallet.address,
            ethers.utils.parseEther('1.0'),
          ),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });
  });
});

describe('StorkIndexAndOraclePriceAdapter', function () {
  let ExchangeIndexPriceAdapterMockFactory: ExchangeIndexPriceAdapterMock__factory;
  let ownerWallet: SignerWithAddress;
  let publisherWallet: SignerWithAddress;
  let storkVerifier: StorkVerifierMock;
  let StorkVerifierMockFactory: StorkVerifierMock__factory;
  let StorkIndexAndOraclePriceAdapterFactory: StorkIndexAndOraclePriceAdapter__factory;

  before(async () => {
    await network.provider.send('hardhat_reset');
    ExchangeIndexPriceAdapterMockFactory = await ethers.getContractFactory(
      'ExchangeIndexPriceAdapterMock',
    );
    [StorkVerifierMockFactory, StorkIndexAndOraclePriceAdapterFactory] =
      await Promise.all([
        ethers.getContractFactory('StorkVerifierMock'),
        ethers.getContractFactory('StorkIndexAndOraclePriceAdapter'),
      ]);

    ownerWallet = (await ethers.getSigners())[0];
    publisherWallet = (await ethers.getSigners())[5];
  });

  beforeEach(async () => {
    storkVerifier = await StorkVerifierMockFactory.deploy();
  });

  describe('deploy', async function () {
    it('should work for valid arguments', async () => {
      await StorkIndexAndOraclePriceAdapterFactory.deploy(
        ownerWallet.address,
        [publisherWallet.address],
        storkVerifier.address,
      );
    });

    it('should revert for invalid activator', async () => {
      await expect(
        StorkIndexAndOraclePriceAdapterFactory.deploy(
          ethers.constants.AddressZero,
          [publisherWallet.address],
          storkVerifier.address,
        ),
      ).to.eventually.be.rejectedWith(/invalid activator/i);
    });

    it('should revert for missing publisher wallets', async () => {
      await expect(
        StorkIndexAndOraclePriceAdapterFactory.deploy(
          ownerWallet.address,
          [],
          storkVerifier.address,
        ),
      ).to.eventually.be.rejectedWith(/missing publisher wallets/i);
    });

    it('should revert for invalid publisher wallet', async () => {
      await expect(
        StorkIndexAndOraclePriceAdapterFactory.deploy(
          ownerWallet.address,
          [ethers.constants.AddressZero],
          storkVerifier.address,
        ),
      ).to.eventually.be.rejectedWith(/invalid publisher wallet/i);
    });

    it('should revert for invalid verifier address', async () => {
      await expect(
        StorkIndexAndOraclePriceAdapterFactory.deploy(
          ownerWallet.address,
          [publisherWallet.address],
          ethers.constants.AddressZero,
        ),
      ).to.eventually.be.rejectedWith(/invalid verifier address/i);
    });
  });

  describe('loadPriceForBaseAssetSymbol', async function () {
    let exchangeMock: ExchangeIndexPriceAdapterMock;
    let indexPriceAdapter: StorkIndexAndOraclePriceAdapter;

    beforeEach(async () => {
      indexPriceAdapter = await StorkIndexAndOraclePriceAdapterFactory.deploy(
        ownerWallet.address,
        [publisherWallet.address],
        storkVerifier.address,
      );
      exchangeMock = await ExchangeIndexPriceAdapterMockFactory.deploy(
        indexPriceAdapter.address,
      );
      await indexPriceAdapter.setActive(exchangeMock.address);
    });

    it('should work when price is in storage', async () => {
      const priceInDecimal = '1900.00000000';

      const indexPricePayload = await buildStorkPricePayload(
        baseAssetSymbol,
        publisherWallet,
        priceInDecimal,
      );

      await exchangeMock.validateIndexPricePayload(indexPricePayload);

      const price = (
        await indexPriceAdapter.loadPriceForBaseAssetSymbol(baseAssetSymbol)
      ).toString();
      expect(price).to.equal(decimalToPips(priceInDecimal));
    });

    it('should not store outdated price', async () => {
      const priceInDecimal = '1900.00000000';

      const indexPricePayload = await buildStorkPricePayload(
        baseAssetSymbol,
        publisherWallet,
        priceInDecimal,
      );

      await exchangeMock.validateIndexPricePayload(indexPricePayload);

      const indexPricePayload2 = await buildStorkPricePayload(
        baseAssetSymbol,
        publisherWallet,
        '1234.67890000',
        (await getLatestBlockTimestampInSeconds()) - 10000,
      );
      await exchangeMock.validateIndexPricePayload(indexPricePayload2);

      const price = (
        await indexPriceAdapter.loadPriceForBaseAssetSymbol(baseAssetSymbol)
      ).toString();
      expect(price).to.equal(decimalToPips(priceInDecimal));
    });

    it('should revert for missing price', async () => {
      await expect(
        indexPriceAdapter.loadPriceForBaseAssetSymbol(baseAssetSymbol),
      ).to.eventually.be.rejectedWith(/missing price/i);
    });
  });

  describe('setActive', async function () {
    let exchange: Exchange_v4;
    let indexPriceAdapter: StorkIndexAndOraclePriceAdapter;
    let oldIndexPriceAdapter: IDEXIndexAndOraclePriceAdapter;

    beforeEach(async () => {
      const results = await deployContractsExceptCustodian(ownerWallet);
      exchange = results.exchange;
      oldIndexPriceAdapter = results.indexPriceAdapter;

      indexPriceAdapter = await StorkIndexAndOraclePriceAdapterFactory.deploy(
        ownerWallet.address,
        [publisherWallet.address],
        storkVerifier.address,
      );
    });

    it('should work for valid contract address', async () => {
      await indexPriceAdapter.setActive(exchange.address);

      await expect(indexPriceAdapter.exchange()).to.eventually.equal(
        exchange.address,
      );
    });

    it('should migrate latest prices', async () => {
      await exchange.setDispatcher(ownerWallet.address);
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
      await exchange.connect(ownerWallet).activateMarket(baseAssetSymbol);
      await exchange
        .connect(ownerWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            oldIndexPriceAdapter.address,
            await buildIndexPriceWithValue(
              exchange.address,
              ownerWallet,
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

  describe('validateIndexPricePayload', async function () {
    let indexPriceAdapter: StorkIndexAndOraclePriceAdapter;

    beforeEach(async () => {
      indexPriceAdapter = await StorkIndexAndOraclePriceAdapterFactory.deploy(
        ownerWallet.address,
        [publisherWallet.address],
        storkVerifier.address,
      );
    });

    it('should revert when not called by exchange', async () => {
      await expect(
        indexPriceAdapter.validateIndexPricePayload('0x00'),
      ).to.eventually.be.rejectedWith(/exchange not set/i);

      const exchange = (await deployContractsExceptCustodian(ownerWallet))
        .exchange;
      await indexPriceAdapter.setActive(exchange.address);
      await expect(
        indexPriceAdapter.validateIndexPricePayload('0x00'),
      ).to.eventually.be.rejectedWith(/caller must be exchange/i);
    });

    it('should revert when price is zero', async () => {
      const exchangeMock = await ExchangeIndexPriceAdapterMockFactory.deploy(
        indexPriceAdapter.address,
      );
      await indexPriceAdapter.setActive(exchangeMock.address);

      await expect(
        exchangeMock.validateIndexPricePayload(
          await buildStorkPricePayload(
            baseAssetSymbol,
            publisherWallet,
            '0.00000000',
          ),
        ),
      ).to.eventually.be.rejectedWith(/unexpected non-positive price/i);
    });
  });

  describe('validateInitialIndexPricePayloadAdmin', async function () {
    let exchange: Exchange_v4;
    let indexPriceAdapter: StorkIndexAndOraclePriceAdapter;
    let storkAdapter: StorkIndexAndOraclePriceAdapter;

    beforeEach(async () => {
      exchange = (await deployContractsExceptCustodian(ownerWallet)).exchange;
      storkAdapter = await StorkIndexAndOraclePriceAdapterFactory.deploy(
        ownerWallet.address,
        [publisherWallet.address],
        storkVerifier.address,
      );
      indexPriceAdapter = await StorkIndexAndOraclePriceAdapterFactory.deploy(
        ownerWallet.address,
        [publisherWallet.address],
        storkVerifier.address,
      );
    });

    it('should work when no price yet exists', async () => {
      const priceInDecimal = '1900.00000000';

      await storkAdapter.setActive(exchange.address);

      await expect(
        storkAdapter.loadPriceForBaseAssetSymbol(baseAssetSymbol),
      ).to.eventually.be.rejectedWith(/missing price/i);

      await storkAdapter.validateInitialIndexPricePayloadAdmin(
        buildStorkPricePayload(
          baseAssetSymbol,
          publisherWallet,
          priceInDecimal,
        ),
      );

      expect(
        (
          await storkAdapter.loadPriceForBaseAssetSymbol(baseAssetSymbol)
        ).toString(),
      ).to.equal(decimalToPips(priceInDecimal));
    });

    it('should revert when price is zero', async () => {
      const exchangeMock = await ExchangeIndexPriceAdapterMockFactory.deploy(
        indexPriceAdapter.address,
      );
      await indexPriceAdapter.setActive(exchangeMock.address);

      await expect(
        indexPriceAdapter.validateInitialIndexPricePayloadAdmin(
          await buildStorkPricePayload(
            baseAssetSymbol,
            publisherWallet,
            '0.00000000',
            (await getLatestBlockTimestampInSeconds()) - 10000,
          ),
        ),
      ).to.eventually.be.rejectedWith(/unexpected non-positive price/i);
    });

    it('should revert when not sent by admin', async () => {
      await expect(
        indexPriceAdapter
          .connect((await ethers.getSigners())[8])
          .validateInitialIndexPricePayloadAdmin(
            await buildStorkPricePayload(
              baseAssetSymbol,
              publisherWallet,
              '1900.00000000',
            ),
          ),
      ).to.eventually.be.rejectedWith(/caller must be admin/i);
    });

    it('should revert when exchange is not set', async () => {
      await expect(
        indexPriceAdapter.validateInitialIndexPricePayloadAdmin(
          await buildStorkPricePayload(
            baseAssetSymbol,
            publisherWallet,
            '1900.00000000',
          ),
        ),
      ).to.eventually.be.rejectedWith(/exchange not set/i);
    });

    it('should revert when price already exists', async () => {
      await indexPriceAdapter.setActive(exchange.address);

      await indexPriceAdapter.validateInitialIndexPricePayloadAdmin(
        await buildStorkPricePayload(
          baseAssetSymbol,
          publisherWallet,
          '1900.00000000',
        ),
      );

      await expect(
        indexPriceAdapter.validateInitialIndexPricePayloadAdmin(
          await buildStorkPricePayload(
            baseAssetSymbol,
            publisherWallet,
            '1900.00000000',
          ),
        ),
      ).to.eventually.be.rejectedWith(/price already exists for market/i);
    });

    it('should revert for invalid signer', async () => {
      const exchangeMock = await ExchangeIndexPriceAdapterMockFactory.deploy(
        indexPriceAdapter.address,
      );
      await indexPriceAdapter.setActive(exchangeMock.address);

      await expect(
        indexPriceAdapter.validateInitialIndexPricePayloadAdmin(
          await buildStorkPricePayload(
            baseAssetSymbol,
            ownerWallet,
            '0.00000000',
            await getLatestBlockTimestampInSeconds(),
          ),
        ),
      ).to.eventually.be.rejectedWith(/invalid index price signer/i);
    });

    it('should revert for invalid signature', async () => {
      const exchangeMock = await ExchangeIndexPriceAdapterMockFactory.deploy(
        indexPriceAdapter.address,
      );
      await indexPriceAdapter.setActive(exchangeMock.address);

      const storkPrice = new BigNumber('1900.00000000')
        .shiftedBy(18)
        .integerValue(BigNumber.ROUND_DOWN)
        .toFixed(0);
      const timestamp = await getLatestBlockTimestampInSeconds();

      const hash = ethers.utils.solidityKeccak256(
        ['address', 'string', 'uint256', 'uint256'],
        [
          publisherWallet.address,
          `${baseAssetSymbol}${quoteAssetSymbol}`,
          timestamp,
          storkPrice,
        ],
      );

      const signature = await ownerWallet.signMessage(
        ethers.utils.arrayify(hash),
      );
      const r = signature.slice(0, 66);
      const s = '0x' + signature.slice(66, 130);
      const v = '0x' + signature.slice(130, 132);

      const payload = ethers.utils.defaultAbiCoder.encode(
        [
          'address',
          'string',
          'uint256',
          'uint256',
          'bytes32',
          'bytes32',
          'uint8',
        ],
        [
          publisherWallet.address,
          baseAssetSymbol,
          timestamp,
          storkPrice,
          r,
          s,
          v,
        ],
      );

      await expect(
        indexPriceAdapter.validateInitialIndexPricePayloadAdmin(payload),
      ).to.eventually.be.rejectedWith(/invalid index price signature/i);
    });

    it('should revert for non-positive price after pip conversion', async () => {
      const exchangeMock = await ExchangeIndexPriceAdapterMockFactory.deploy(
        indexPriceAdapter.address,
      );
      await indexPriceAdapter.setActive(exchangeMock.address);

      const storkPrice = new BigNumber('0.000000001')
        .shiftedBy(18)
        .integerValue(BigNumber.ROUND_DOWN)
        .toFixed(0);
      const timestamp = await getLatestBlockTimestampInSeconds();

      const hash = ethers.utils.solidityKeccak256(
        ['address', 'string', 'uint256', 'uint256'],
        [
          publisherWallet.address,
          `${baseAssetSymbol}${quoteAssetSymbol}`,
          timestamp,
          storkPrice,
        ],
      );

      const signature = await publisherWallet.signMessage(
        ethers.utils.arrayify(hash),
      );
      const r = signature.slice(0, 66);
      const s = '0x' + signature.slice(66, 130);
      const v = '0x' + signature.slice(130, 132);

      const payload = ethers.utils.defaultAbiCoder.encode(
        [
          'address',
          'string',
          'uint256',
          'uint256',
          'bytes32',
          'bytes32',
          'uint8',
        ],
        [
          publisherWallet.address,
          baseAssetSymbol,
          timestamp,
          storkPrice,
          r,
          s,
          v,
        ],
      );

      await expect(
        indexPriceAdapter.validateInitialIndexPricePayloadAdmin(payload),
      ).to.eventually.be.rejectedWith(/unexpected non-positive price/i);
    });
  });
});

async function buildPythPricePayload(
  priceId: Uint8Array,
  price: string,
  decimals = 8,
) {
  const timestamp = await getLatestBlockTimestampInSeconds();

  const pythPrice = ethers.utils.defaultAbiCoder.encode(
    [
      'tuple(bytes32,tuple(int64,uint64,int32,uint256),tuple(int64,uint64,int32,uint256))',
    ],
    [
      [
        priceId,
        [price, 100, -1 * decimals, timestamp],
        [price, 100, -1 * decimals, timestamp],
      ],
    ],
  );

  return ethers.utils.defaultAbiCoder.encode(
    ['bytes32', 'bytes'],
    [priceId, pythPrice],
  );
}

async function buildStorkPricePayload(
  baseAssetSymbol: string,
  publisherWallet: SignerWithAddress,
  price: string,
  timestampOverride?: number,
) {
  const storkPrice = new BigNumber(price)
    .shiftedBy(18)
    .integerValue(BigNumber.ROUND_DOWN)
    .toFixed(0);
  const timestamp =
    timestampOverride ?? (await getLatestBlockTimestampInSeconds());

  const hash = ethers.utils.solidityKeccak256(
    ['address', 'string', 'uint256', 'uint256'],
    [
      publisherWallet.address,
      `${baseAssetSymbol}${quoteAssetSymbol}`,
      timestamp,
      storkPrice,
    ],
  );

  const signature = await publisherWallet.signMessage(
    ethers.utils.arrayify(hash),
  );
  const r = signature.slice(0, 66);
  const s = '0x' + signature.slice(66, 130);
  const v = '0x' + signature.slice(130, 132);

  return ethers.utils.defaultAbiCoder.encode(
    ['address', 'string', 'uint256', 'uint256', 'bytes32', 'bytes32', 'uint8'],
    [publisherWallet.address, baseAssetSymbol, timestamp, storkPrice, r, s, v],
  );
}
