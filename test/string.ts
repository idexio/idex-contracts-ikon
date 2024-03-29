import { ethers, network } from 'hardhat';

import { expect } from './helpers';

import type { StringMock } from '../typechain-types';

describe.only('String', function () {
  let stringMock: StringMock;

  before(async () => {
    await network.provider.send('hardhat_reset');

    const StringMockFactory = await ethers.getContractFactory('StringMock');
    stringMock = await StringMockFactory.deploy();
  });

  describe('startsWith', async function () {
    it('should return true for valid prefixes', async () => {
      expect(await stringMock.startsWith('abc', 'a')).to.equal(true);
    });
  });
});
