import BigNumber from 'bignumber.js';
import { ethers } from 'hardhat';

import { expect } from './helpers';
import type { SortedStringSetMock } from '../typechain-types';
import { compareMarketSymbols } from '../lib';

describe('SortedStringSet', function () {
  let sortedStringSetMock: SortedStringSetMock;

  before(async () => {
    const SortedStringSetMockFactory = await ethers.getContractFactory(
      'SortedStringSetMock',
    );
    sortedStringSetMock = await SortedStringSetMockFactory.deploy();
  });

  describe('indexOf', async function () {
    it('should work for valid arguments', async () => {
      const array = ['a', 'b', 'c', 'd'].sort(compareMarketSymbols);
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
      let beforeInsert = ['a', 'b', 'c', 'd'].sort(compareMarketSymbols);
      let afterInsert = ['a', 'b', 'c', 'd', 'e'].sort(compareMarketSymbols);
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
      let before1 = ['a', 'b'].sort(compareMarketSymbols);
      let before2 = ['b', 'c', 'd'].sort(compareMarketSymbols);
      let afterMerge = ['a', 'b', 'c', 'd'].sort(compareMarketSymbols);
      await expect(
        sortedStringSetMock.merge(before1, before2),
      ).to.eventually.deep.equal(afterMerge);
    });
  });

  describe('remove', async function () {
    it('should work for valid arguments', async () => {
      let beforeRemove = ['a', 'b', 'c', 'd', 'e'].sort(compareMarketSymbols);
      let afterRemove = ['a', 'b', 'c', 'd'].sort(compareMarketSymbols);
      await expect(
        sortedStringSetMock.remove(beforeRemove, 'e'),
      ).to.eventually.deep.equal(afterRemove);

      beforeRemove = ['a'].sort(compareMarketSymbols);
      await expect(
        sortedStringSetMock.remove(beforeRemove, 'a'),
      ).to.eventually.deep.equal([]);
    });

    it('should revert for invalid argument', async () => {
      let beforeRemove = ['a', 'b', 'c', 'd', 'e'].sort(compareMarketSymbols);
      await expect(
        sortedStringSetMock.remove(beforeRemove, 'f'),
      ).to.eventually.be.rejectedWith(/element to remove not found/i);
    });
  });
});
