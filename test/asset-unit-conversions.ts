import BigNumber from 'bignumber.js';
import { ethers } from 'hardhat';

import type { AssetUnitConversionsMock } from '../typechain-types';
import { expect } from './helpers';

describe('AssetsUnitConversions', () => {
  let assetsUnitConversionsMock: AssetUnitConversionsMock;

  before(async () => {
    const AssetUnitConversionsMockFactory = await ethers.getContractFactory(
      'AssetUnitConversionsMock',
    );
    assetsUnitConversionsMock = await AssetUnitConversionsMockFactory.deploy();
  });

  describe('assetUnitsToPips', async () => {
    const assetUnitsToPips = async (
      quantity: string,
      decimals: string,
    ): Promise<string> =>
      (
        await assetsUnitConversionsMock.assetUnitsToPips(quantity, decimals)
      ).toString();

    it('should succeed', async () => {
      expect(await assetUnitsToPips('10000000000', '18')).to.equal('1');
      expect(await assetUnitsToPips('10000000000000', '18')).to.equal('1000');
      expect(await assetUnitsToPips('1', '8')).to.equal('1');
      expect(await assetUnitsToPips('1', '2')).to.equal('1000000');
      expect(await assetUnitsToPips('1', '0')).to.equal('100000000');
    });

    it('should truncate fractions of a pip', async () => {
      expect(await assetUnitsToPips('19', '9')).to.equal('1');
      expect(await assetUnitsToPips('1', '9')).to.equal('0');
    });

    it('should revert on uint64 overflow', async () => {
      await expect(
        assetUnitsToPips(new BigNumber(2).exponentiatedBy(128).toFixed(), '8'),
      ).to.eventually.be.rejectedWith(/pip quantity overflows uint64/i);
    });

    it('should revert when token has too many decimals', async () => {
      await expect(
        assetUnitsToPips(new BigNumber(1).toFixed(), '100'),
      ).to.eventually.be.rejectedWith(
        /asset cannot have more than 32 decimals/i,
      );
    });
  });

  describe('pipsToAssetUnits', async () => {
    const pipsToAssetUnits = async (
      quantity: string,
      decimals: string,
    ): Promise<string> =>
      (
        await assetsUnitConversionsMock.pipsToAssetUnits(quantity, decimals)
      ).toString();

    it('should succeed', async () => {
      expect(await pipsToAssetUnits('1', '18')).to.equal('10000000000');
      expect(await pipsToAssetUnits('1000', '18')).to.equal('10000000000000');
      expect(await pipsToAssetUnits('1', '8')).to.equal('1');
      expect(await pipsToAssetUnits('1000000', '2')).to.equal('1');
      expect(await pipsToAssetUnits('100000000', '0')).to.equal('1');
    });

    it('should revert when token has too many decimals', async () => {
      await expect(
        pipsToAssetUnits(new BigNumber(1).toFixed(), '100'),
      ).to.eventually.be.rejectedWith(
        /asset cannot have more than 32 decimals/i,
      );
    });
  });
});
