import { ethers, network } from 'hardhat';
import { decimalToPips } from '../lib';

import {
  ChainlinkAggregatorMock__factory,
  ChainlinkOraclePriceAdapter__factory,
  PythMock,
  PythMock__factory,
  PythOraclePriceAdapter,
  PythOraclePriceAdapter__factory,
} from '../typechain-types';
import {
  baseAssetSymbol,
  expect,
  getLatestBlockTimestampInSeconds,
} from './helpers';

describe('oracle price adapters', function () {
  describe('ChainlinkOraclePriceAdapter', function () {
    let ChainlinkOraclePriceAdapterFactory: ChainlinkOraclePriceAdapter__factory;
    let ChainlinkAggregatorFactory: ChainlinkAggregatorMock__factory;

    before(async () => {
      await network.provider.send('hardhat_reset');
      [ChainlinkAggregatorFactory, ChainlinkOraclePriceAdapterFactory] =
        await Promise.all([
          ethers.getContractFactory('ChainlinkAggregatorMock'),
          ethers.getContractFactory('ChainlinkOraclePriceAdapter'),
        ]);
    });

    describe('deploy', async function () {
      it('should work for valid arguments', async () => {
        await ChainlinkOraclePriceAdapterFactory.deploy(
          [baseAssetSymbol],
          [await (await ChainlinkAggregatorFactory.deploy()).getAddress()],
        );
      });

      it('should revert for mismatched argument lengths', async () => {
        await expect(
          ChainlinkOraclePriceAdapterFactory.deploy(
            [baseAssetSymbol, baseAssetSymbol],
            [await (await ChainlinkAggregatorFactory.deploy()).getAddress()],
          ),
        ).to.eventually.be.rejectedWith(/argument length mismatch/i);
      });

      it('should revert for invalid base asset symbol', async () => {
        await expect(
          ChainlinkOraclePriceAdapterFactory.deploy(
            [''],
            [await (await ChainlinkAggregatorFactory.deploy()).getAddress()],
          ),
        ).to.eventually.be.rejectedWith(/invalid base asset symbol/i);
      });

      it('should revert for invalid await aggregator.getAddress()', async () => {
        await expect(
          ChainlinkOraclePriceAdapterFactory.deploy(
            [baseAssetSymbol, baseAssetSymbol],
            [
              await (await ChainlinkAggregatorFactory.deploy()).getAddress(),
              ethers.ZeroAddress,
            ],
          ),
        ).to.eventually.be.rejectedWith(
          /invalid chainlink await aggregator.getAddress()/i,
        );
      });
    });

    describe('addBaseAssetSymbolAndAggregator', async function () {
      it('should work for valid base asset symbol and aggregator', async () => {
        const adapter = await ChainlinkOraclePriceAdapterFactory.deploy(
          [baseAssetSymbol],
          [await (await ChainlinkAggregatorFactory.deploy()).getAddress()],
        );

        await adapter.addBaseAssetSymbolAndAggregator(
          'XYZ',
          await (await ChainlinkAggregatorFactory.deploy()).getAddress(),
        );
      });

      it('should revert when not sent by admin', async () => {
        const adapter = await ChainlinkOraclePriceAdapterFactory.deploy(
          [baseAssetSymbol],
          [await (await ChainlinkAggregatorFactory.deploy()).getAddress()],
        );

        await expect(
          adapter
            .connect((await ethers.getSigners())[5])
            .addBaseAssetSymbolAndAggregator(
              'XYZ',
              await (await ChainlinkAggregatorFactory.deploy()).getAddress(),
            ),
        ).to.eventually.be.rejectedWith(/caller must be admin/i);
      });

      it('should revert for invalid base asset symbol', async () => {
        const adapter = await ChainlinkOraclePriceAdapterFactory.deploy(
          [baseAssetSymbol],
          [await (await ChainlinkAggregatorFactory.deploy()).getAddress()],
        );

        await expect(
          adapter.addBaseAssetSymbolAndAggregator(
            '',
            await (await ChainlinkAggregatorFactory.deploy()).getAddress(),
          ),
        ).to.eventually.be.rejectedWith(/invalid base asset symbol/i);
      });

      it('should revert for invalid await aggregator.getAddress()', async () => {
        const adapter = await ChainlinkOraclePriceAdapterFactory.deploy(
          [baseAssetSymbol],
          [await (await ChainlinkAggregatorFactory.deploy()).getAddress()],
        );

        await expect(
          adapter.addBaseAssetSymbolAndAggregator('XYZ', ethers.ZeroAddress),
        ).to.eventually.be.rejectedWith(/invalid chainlink aggregator/i);
      });

      it('should revert for already added base asset symbol', async () => {
        const adapter = await ChainlinkOraclePriceAdapterFactory.deploy(
          [baseAssetSymbol],
          [await (await ChainlinkAggregatorFactory.deploy()).getAddress()],
        );

        await expect(
          adapter.addBaseAssetSymbolAndAggregator(
            baseAssetSymbol,
            await (await ChainlinkAggregatorFactory.deploy()).getAddress(),
          ),
        ).to.eventually.be.rejectedWith(/already added base asset symbol/i);
      });

      it('should revert for already added aggregator', async () => {
        const aggregator = await ChainlinkAggregatorFactory.deploy();
        const adapter = await ChainlinkOraclePriceAdapterFactory.deploy(
          [baseAssetSymbol],
          [await aggregator.getAddress()],
        );

        await expect(
          adapter.addBaseAssetSymbolAndAggregator(
            'XYZ',
            await aggregator.getAddress(),
          ),
        ).to.eventually.be.rejectedWith(/already added chainlink aggregator/i);
      });
    });

    describe('loadPriceForBaseAssetSymbol', async function () {
      it('should revert for invalid symbol', async () => {
        const adapter = await ChainlinkOraclePriceAdapterFactory.deploy(
          [baseAssetSymbol],
          [await (await ChainlinkAggregatorFactory.deploy()).getAddress()],
        );

        await expect(
          adapter.loadPriceForBaseAssetSymbol('XYZ'),
        ).to.eventually.be.rejectedWith(/missing aggregator for symbol/i);
      });

      it('should revert for negative feed price', async () => {
        const chainlinkAggregator = await ChainlinkAggregatorFactory.deploy();

        const adapter = await ChainlinkOraclePriceAdapterFactory.deploy(
          [baseAssetSymbol],
          [await chainlinkAggregator.getAddress()],
        );

        await chainlinkAggregator.setPrice(-100);
        await expect(
          adapter.loadPriceForBaseAssetSymbol(baseAssetSymbol),
        ).to.eventually.be.rejectedWith(/unexpected non-positive feed price/i);
      });

      it('should revert for negative price after conversion to pips', async () => {
        const chainlinkAggregator = await ChainlinkAggregatorFactory.deploy();

        const adapter = await ChainlinkOraclePriceAdapterFactory.deploy(
          [baseAssetSymbol],
          [await chainlinkAggregator.getAddress()],
        );

        await chainlinkAggregator.setPrice(1000);
        await chainlinkAggregator.setDecimals(20);
        await expect(
          adapter.loadPriceForBaseAssetSymbol(baseAssetSymbol),
        ).to.eventually.be.rejectedWith(/unexpected non-positive price/i);
      });
    });
  });

  describe('PythOraclePriceAdapter', function () {
    let pyth: PythMock;
    let PythMockFactory: PythMock__factory;
    let PythOraclePriceAdapterFactory: PythOraclePriceAdapter__factory;

    const oneDayInSeconds = 1 * 24 * 60 * 60;

    before(async () => {
      await network.provider.send('hardhat_reset');
      [PythMockFactory, PythOraclePriceAdapterFactory] = await Promise.all([
        ethers.getContractFactory('PythMock'),
        ethers.getContractFactory('PythOraclePriceAdapter'),
      ]);
    });

    beforeEach(async () => {
      pyth = await PythMockFactory.deploy(oneDayInSeconds, 1);
    });

    describe('deploy', async function () {
      it('should work for valid arguments', async () => {
        const pyth = await PythMockFactory.deploy(oneDayInSeconds, 1);

        await PythOraclePriceAdapterFactory.deploy(
          [baseAssetSymbol],
          [ethers.randomBytes(32)],
          await pyth.getAddress(),
        );
      });

      it('should revert for invalid Pyth contract', async () => {
        await expect(
          PythOraclePriceAdapterFactory.deploy(
            [baseAssetSymbol],
            [ethers.randomBytes(32)],
            ethers.ZeroAddress,
          ),
        ).to.eventually.be.rejectedWith(/invalid pyth contract address/i);
      });

      it('should revert for mismatched argument lengths', async () => {
        await expect(
          PythOraclePriceAdapterFactory.deploy(
            [baseAssetSymbol, baseAssetSymbol],
            [ethers.randomBytes(32)],
            await pyth.getAddress(),
          ),
        ).to.eventually.be.rejectedWith(/argument length mismatch/i);

        await expect(
          PythOraclePriceAdapterFactory.deploy(
            [baseAssetSymbol],
            [ethers.randomBytes(32), ethers.randomBytes(32)],
            await pyth.getAddress(),
          ),
        ).to.eventually.be.rejectedWith(/argument length mismatch/i);
      });

      it('should revert for invalid base asset symbol', async () => {
        await expect(
          PythOraclePriceAdapterFactory.deploy(
            [''],
            [ethers.randomBytes(32)],
            await pyth.getAddress(),
          ),
        ).to.eventually.be.rejectedWith(/invalid base asset symbol/i);
      });

      it('should revert for invalid price ID', async () => {
        await expect(
          PythOraclePriceAdapterFactory.deploy(
            [baseAssetSymbol],
            [
              '0x0000000000000000000000000000000000000000000000000000000000000000',
            ],
            await pyth.getAddress(),
          ),
        ).to.eventually.be.rejectedWith(/invalid price id/i);
      });
    });

    describe('addBaseAssetSymbolAndPriceId', async function () {
      let adapter: PythOraclePriceAdapter;
      const priceId = ethers.randomBytes(32);

      beforeEach(async () => {
        adapter = await PythOraclePriceAdapterFactory.deploy(
          [baseAssetSymbol],
          [priceId],
          await pyth.getAddress(),
        );
      });

      it('should work for valid base asset symbol and price ID', async () => {
        await adapter.addBaseAssetSymbolAndPriceId(
          'XYZ',
          ethers.randomBytes(32),
        );
      });

      it('should revert when not sent by admin', async () => {
        await expect(
          adapter
            .connect((await ethers.getSigners())[5])
            .addBaseAssetSymbolAndPriceId('XYZ', ethers.randomBytes(32)),
        ).to.eventually.be.rejectedWith(/caller must be admin/i);
      });

      it('should revert for invalid base asset symbol', async () => {
        await expect(
          adapter.addBaseAssetSymbolAndPriceId('', ethers.randomBytes(32)),
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
            ethers.randomBytes(32),
          ),
        ).to.eventually.be.rejectedWith(/already added base asset symbol/i);
      });

      it('should revert for already added price ID', async () => {
        await expect(
          adapter.addBaseAssetSymbolAndPriceId('XYZ', priceId),
        ).to.eventually.be.rejectedWith(/already added price ID/i);
      });
    });

    describe('loadPriceForBaseAssetSymbol', async function () {
      let adapter: PythOraclePriceAdapter;
      const price = decimalToPips('2000.00000000');
      const priceId = ethers.randomBytes(32);

      beforeEach(async () => {
        adapter = await PythOraclePriceAdapterFactory.deploy(
          [baseAssetSymbol],
          [priceId],
          await pyth.getAddress(),
        );
      });

      it('should work for valid symbol with 8 decimals', async () => {
        await updatePythPrice(
          pyth,
          priceId,
          price,
          await getLatestBlockTimestampInSeconds(),
          8,
        );

        expect(
          (
            await adapter.loadPriceForBaseAssetSymbol(baseAssetSymbol)
          ).toString(),
        ).to.equal(price);
      });

      it('should work for valid symbol with 6 decimals', async () => {
        await updatePythPrice(
          pyth,
          priceId,
          price,
          await getLatestBlockTimestampInSeconds(),
          6,
        );

        expect(
          (
            await adapter.loadPriceForBaseAssetSymbol(baseAssetSymbol)
          ).toString(),
        ).to.equal(decimalToPips('200000.00000000'));
      });

      it('should work for valid symbol with 10 decimals', async () => {
        await updatePythPrice(
          pyth,
          priceId,
          price,
          await getLatestBlockTimestampInSeconds(),
          10,
        );

        expect(
          (
            await adapter.loadPriceForBaseAssetSymbol(baseAssetSymbol)
          ).toString(),
        ).to.equal(decimalToPips('20.00000000'));
      });

      it('should revert for invalid base asset symbol', async () => {
        await expect(
          adapter.loadPriceForBaseAssetSymbol('XYZ'),
        ).to.eventually.be.rejectedWith(/invalid base asset symbol/i);
      });

      it('should revert for zero price', async () => {
        await updatePythPrice(
          pyth,
          priceId,
          decimalToPips('0.00000000'),
          await getLatestBlockTimestampInSeconds(),
          8,
        );

        await expect(
          adapter.loadPriceForBaseAssetSymbol(baseAssetSymbol),
        ).to.eventually.be.rejectedWith(/unexpected non-positive price/i);
      });

      it('should revert for zero price after pip conversion', async () => {
        await updatePythPrice(
          pyth,
          priceId,
          decimalToPips('0.00000001'),
          await getLatestBlockTimestampInSeconds(),
          20,
        );

        await expect(
          adapter.loadPriceForBaseAssetSymbol(baseAssetSymbol),
        ).to.eventually.be.rejectedWith(/unexpected non-positive price/i);
      });

      it('should revert for negative price', async () => {
        await updatePythPrice(
          pyth,
          priceId,
          decimalToPips('-2000.00000000'),
          await getLatestBlockTimestampInSeconds(),
          8,
        );

        await expect(
          adapter.loadPriceForBaseAssetSymbol(baseAssetSymbol),
        ).to.eventually.be.rejectedWith(/unexpected non-positive price/i);
      });
    });

    describe('setActive', async function () {
      it('should work', async () => {
        const adapter = await PythOraclePriceAdapterFactory.deploy(
          [baseAssetSymbol],
          [ethers.randomBytes(32)],
          await pyth.getAddress(),
        );
        await adapter.setActive(ethers.ZeroAddress);
      });
    });
  });
});

async function updatePythPrice(
  pyth: PythMock,
  priceId: Uint8Array,
  price: string,
  timestamp: number,
  decimals = 8,
) {
  await pyth.updatePriceFeeds(
    [
      ethers.AbiCoder.defaultAbiCoder().encode(
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
      ),
    ],
    { value: 1 },
  );
}
