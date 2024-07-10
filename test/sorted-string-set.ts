import BigNumber from 'bignumber.js';
import { ethers, network } from 'hardhat';

import { compareBaseAssetSymbols } from '../lib';

import { expect } from './helpers';

import type { SortedStringSetMock } from '../typechain-types';

describe('SortedStringSet', function () {
  let sortedStringSetMock: SortedStringSetMock;

  before(async () => {
    await network.provider.send('hardhat_reset');

    const SortedStringSetMockFactory = await ethers.getContractFactory(
      'SortedStringSetMock',
    );
    sortedStringSetMock = await SortedStringSetMockFactory.deploy();
  });

  describe('indexOf', async function () {
    it('should work for valid arguments', async () => {
      const array = ['a', 'b', 'c', 'd'].sort(compareBaseAssetSymbols);
      expect(await sortedStringSetMock.indexOf(array, 'c')).to.equal(
        array.indexOf('c'),
      );
      expect(
        (await sortedStringSetMock.indexOf(array, 'e')).toString(),
      ).to.equal(new BigNumber(2).pow(256).minus(1).toFixed());
    });
  });

  describe('insertSorted', async function () {
    it('should work for valid arguments', async () => {
      const beforeInsert = ['a', 'b', 'c', 'd'].sort(compareBaseAssetSymbols);
      const afterInsert = ['a', 'b', 'c', 'd', 'e'].sort(
        compareBaseAssetSymbols,
      );
      await expect(
        sortedStringSetMock.insertSorted(beforeInsert, 'e'),
      ).to.eventually.deep.equal(afterInsert);

      await expect(
        sortedStringSetMock.insertSorted(beforeInsert, 'd'),
      ).to.eventually.deep.equal(beforeInsert);
    });
  });

  describe('merge', async function () {
    it('should work for valid arguments', async () => {
      const before1 = ['a', 'b'].sort(compareBaseAssetSymbols);
      const before2 = ['b', 'c', 'd'].sort(compareBaseAssetSymbols);
      const afterMerge = ['a', 'b', 'c', 'd'].sort(compareBaseAssetSymbols);
      await expect(
        sortedStringSetMock.merge(before1, before2),
      ).to.eventually.deep.equal(afterMerge);
    });
  });

  describe('remove', async function () {
    it('should work for valid arguments', async () => {
      let beforeRemove = ['a', 'b', 'c', 'd', 'e'].sort(
        compareBaseAssetSymbols,
      );
      const afterRemove = ['a', 'b', 'c', 'd'].sort(compareBaseAssetSymbols);
      await expect(
        sortedStringSetMock.remove(beforeRemove, 'e'),
      ).to.eventually.deep.equal(afterRemove);

      beforeRemove = ['a'].sort(compareBaseAssetSymbols);
      await expect(
        sortedStringSetMock.remove(beforeRemove, 'a'),
      ).to.eventually.deep.equal([]);
    });

    it('should revert for invalid argument', async () => {
      const beforeRemove = ['a', 'b', 'c', 'd', 'e'].sort(
        compareBaseAssetSymbols,
      );
      await expect(
        sortedStringSetMock.remove(beforeRemove, 'f'),
      ).to.eventually.be.rejectedWith(/element to remove not found/i);
    });
  });
});
