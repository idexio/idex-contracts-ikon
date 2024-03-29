import { ethers, network } from 'hardhat';

import { expect } from './helpers';

import type { StringMock } from '../typechain-types';

describe('String', function () {
  let stringMock: StringMock;

  before(async () => {
    await network.provider.send('hardhat_reset');

    const StringMockFactory = await ethers.getContractFactory('StringMock');
    stringMock = await StringMockFactory.deploy();
  });

  describe('startsWith', async function () {
    it('should return true for valid prefixes', async () => {
      expect(await stringMock.startsWith('abc', 'a')).to.equal(true);
      expect(await stringMock.startsWith('abc', 'ab')).to.equal(true);
      expect(await stringMock.startsWith('abc', 'abc')).to.equal(true);
    });

    it('should return false for invalid prefixes', async () => {
      expect(await stringMock.startsWith('abc', 'b')).to.equal(false);
      expect(await stringMock.startsWith('abc', 'aaa')).to.equal(false);
      expect(await stringMock.startsWith('abc', 'abcd')).to.equal(false);
    });
  });
});
