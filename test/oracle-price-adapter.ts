import { ethers, network } from 'hardhat';

import {
  ChainlinkAggregatorMock__factory,
  ChainlinkOraclePriceAdapter,
  ChainlinkOraclePriceAdapter__factory,
} from '../typechain-types';
import { baseAssetSymbol, expect } from './helpers';

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
      ).to.eventually.be.rejectedWith(/invalid chainlink aggregator address/i);
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