import { ethers, network } from 'hardhat';
import { decimalToPips } from '../lib';

import {
  ChainlinkAggregatorMock__factory,
  ChainlinkOraclePriceAdapter__factory,
  PythMock,
  PythMock__factory,
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

      it.only('should revert for mismatched argument lengths', async () => {
        await expect(
          PythOraclePriceAdapterFactory.deploy(
            ethers.constants.AddressZero,
            [baseAssetSymbol, baseAssetSymbol],
            [ethers.utils.randomBytes(32)],
          ),
        ).to.eventually.be.rejectedWith(/argument length mismatch/i);

        await expect(
          PythOraclePriceAdapterFactory.deploy(
            ethers.constants.AddressZero,
            [baseAssetSymbol],
            [ethers.utils.randomBytes(32), ethers.utils.randomBytes(32)],
          ),
        ).to.eventually.be.rejectedWith(/argument length mismatch/i);
      });
    });

    describe('loadPriceForBaseAssetSymbol', async function () {
      let pyth: PythMock;
      const price = decimalToPips('2000.00000000');
      const priceId = ethers.utils.randomBytes(32);

      beforeEach(async () => {
        pyth = await PythMockFactory.deploy(oneDayInSeconds, 1);
        await updatePythPrice(
          pyth,
          priceId,
          price,
          await getLatestBlockTimestampInSeconds(),
        );
      });

      it('should work for valid symbol with 8 decimals', async () => {
        const adapter = await PythOraclePriceAdapterFactory.deploy(
          pyth.address,
          [baseAssetSymbol],
          [priceId],
        );

        expect(
          (
            await adapter.loadPriceForBaseAssetSymbol(baseAssetSymbol)
          ).toString(),
        ).to.equal(price);
      });
    });
  });
});

async function updatePythPrice(
  pyth: PythMock,
  priceId: Uint8Array,
  price: string,
  timestamp: number,
) {
  await pyth.updatePriceFeeds(
    [
      ethers.utils.defaultAbiCoder.encode(
        [
          'tuple(bytes32,tuple(int64,uint64,int32,uint256),tuple(int64,uint64,int32,uint256))',
        ],
        [[priceId, [price, 100, -8, timestamp], [price, 100, -8, timestamp]]],
      ),
    ],
    { value: 1 },
  );
}
