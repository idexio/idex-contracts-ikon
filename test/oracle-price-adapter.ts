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
          [(await ChainlinkAggregatorFactory.deploy()).address],
        );
      });

      it('should revert for mismatched argument lengths', async () => {
        await expect(
          ChainlinkOraclePriceAdapterFactory.deploy(
            [baseAssetSymbol, baseAssetSymbol],
            [(await ChainlinkAggregatorFactory.deploy()).address],
          ),
        ).to.eventually.be.rejectedWith(/argument length mismatch/i);
      });

      it('should revert for invalid aggregator address', async () => {
        await expect(
          ChainlinkOraclePriceAdapterFactory.deploy(
            [baseAssetSymbol, baseAssetSymbol],
            [
              (await ChainlinkAggregatorFactory.deploy()).address,
              ethers.constants.AddressZero,
            ],
          ),
        ).to.eventually.be.rejectedWith(
          /invalid chainlink aggregator address/i,
        );
      });
    });

    describe('loadPriceForBaseAssetSymbol', async function () {
      it('should revert for invalid symbol', async () => {
        const adapter = await ChainlinkOraclePriceAdapterFactory.deploy(
          [baseAssetSymbol],
          [(await ChainlinkAggregatorFactory.deploy()).address],
        );

        await expect(
          adapter.loadPriceForBaseAssetSymbol('XYZ'),
        ).to.eventually.be.rejectedWith(/missing aggregator for symbol/i);
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
          pyth.address,
          [baseAssetSymbol],
          [ethers.utils.randomBytes(32)],
        );
      });

      it('should revert for invalid Pyth contract', async () => {
        await expect(
          PythOraclePriceAdapterFactory.deploy(
            ethers.constants.AddressZero,
            [baseAssetSymbol],
            [ethers.utils.randomBytes(32)],
          ),
        ).to.eventually.be.rejectedWith(/invalid pyth contract address/i);
      });

      it('should revert for mismatched argument lengths', async () => {
        await expect(
          PythOraclePriceAdapterFactory.deploy(
            pyth.address,
            [baseAssetSymbol, baseAssetSymbol],
            [ethers.utils.randomBytes(32)],
          ),
        ).to.eventually.be.rejectedWith(/argument length mismatch/i);

        await expect(
          PythOraclePriceAdapterFactory.deploy(
            pyth.address,
            [baseAssetSymbol],
            [ethers.utils.randomBytes(32), ethers.utils.randomBytes(32)],
          ),
        ).to.eventually.be.rejectedWith(/argument length mismatch/i);
      });

      it('should revert for invalid price ID', async () => {
        await expect(
          PythOraclePriceAdapterFactory.deploy(
            pyth.address,
            [baseAssetSymbol],
            [
              '0x0000000000000000000000000000000000000000000000000000000000000000',
            ],
          ),
        ).to.eventually.be.rejectedWith(/invalid price id/i);
      });
    });

    describe('loadPriceForBaseAssetSymbol', async function () {
      let adapter: PythOraclePriceAdapter;
      const price = decimalToPips('2000.00000000');
      const priceId = ethers.utils.randomBytes(32);

      beforeEach(async () => {
        adapter = await PythOraclePriceAdapterFactory.deploy(
          pyth.address,
          [baseAssetSymbol],
          [priceId],
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
          pyth.address,
          [baseAssetSymbol],
          [ethers.utils.randomBytes(32)],
        );
        await adapter.setActive(ethers.constants.AddressZero);
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
      ethers.utils.defaultAbiCoder.encode(
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
