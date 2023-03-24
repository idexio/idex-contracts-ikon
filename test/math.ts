import BigNumber from 'bignumber.js';
import { ethers, network } from 'hardhat';

import { expect } from './helpers';
import type { MathMock } from '../typechain-types';

describe('Math', function () {
  let mathMock: MathMock;

  before(async () => {
    await network.provider.send('hardhat_reset');

    const MathMockFactory = await ethers.getContractFactory('MathMock');
    mathMock = await MathMockFactory.deploy();
  });

  describe('divideRoundUp', async function () {
    it('should work for valid arguments', async () => {
      expect((await mathMock.divideRoundUp(4, 2)).toString()).equal('2');
      expect((await mathMock.divideRoundUp(5, 2)).toString()).equal('3');
      expect((await mathMock.divideRoundUp(6, 2)).toString()).equal('3');
      expect((await mathMock.divideRoundUp(2, 3)).toString()).equal('1');
      expect((await mathMock.divideRoundUp(3, 100)).toString()).equal('1');
      expect((await mathMock.divideRoundUp(0, 100)).toString()).equal('0');
    });
  });

  describe('divideRoundNearest', async function () {
    it('should work for valid arguments', async () => {
      expect((await mathMock.divideRoundNearest(4, 2)).toString()).equal('2');
      expect((await mathMock.divideRoundNearest(5, 2)).toString()).equal('3');
      expect((await mathMock.divideRoundNearest(6, 2)).toString()).equal('3');
      expect((await mathMock.divideRoundNearest(2, 3)).toString()).equal('1');
      expect((await mathMock.divideRoundNearest(10, 4)).toString()).equal('3');
      expect((await mathMock.divideRoundNearest(10, 6)).toString()).equal('2');
      expect((await mathMock.divideRoundNearest(10, 7)).toString()).equal('1');
      expect((await mathMock.divideRoundNearest(3, 100)).toString()).equal('0');
      expect((await mathMock.divideRoundNearest(0, 100)).toString()).equal('0');
    });
  });

  describe('maxUnsigned', async function () {
    it('should work for valid arguments', async () => {
      expect((await mathMock.maxUnsigned(1, 2)).toString()).equal('2');
      expect((await mathMock.maxUnsigned(2, 1)).toString()).equal('2');
      expect((await mathMock.maxUnsigned(100, 100)).toString()).equal('100');
      expect((await mathMock.maxUnsigned(0, 0)).toString()).equal('0');
      expect((await mathMock.maxUnsigned(0, 33)).toString()).equal('33');
      expect((await mathMock.maxUnsigned(33, 0)).toString()).equal('33');
    });
  });

  describe('maxSigned', async function () {
    it('should work for valid arguments', async () => {
      expect((await mathMock.maxSigned(1, 2)).toString()).equal('2');
      expect((await mathMock.maxSigned(2, 1)).toString()).equal('2');
      expect((await mathMock.maxSigned(100, 100)).toString()).equal('100');
      expect((await mathMock.maxSigned(0, 0)).toString()).equal('0');
      expect((await mathMock.maxSigned(0, 33)).toString()).equal('33');
      expect((await mathMock.maxSigned(33, 0)).toString()).equal('33');
      expect((await mathMock.maxSigned(-33, 0)).toString()).equal('0');
      expect((await mathMock.maxSigned(100, -100)).toString()).equal('100');
      expect((await mathMock.maxSigned(-101, -100)).toString()).equal('-100');
      expect((await mathMock.maxSigned(0, -1)).toString()).equal('0');
      expect((await mathMock.maxSigned(0, 1)).toString()).equal('1');
    });
  });

  describe('minUnsigned', async function () {
    it('should work for valid arguments', async () => {
      expect((await mathMock.minUnsigned(1, 2)).toString()).equal('1');
      expect((await mathMock.minUnsigned(2, 1)).toString()).equal('1');
      expect((await mathMock.minUnsigned(100, 100)).toString()).equal('100');
      expect((await mathMock.minUnsigned(0, 0)).toString()).equal('0');
      expect((await mathMock.minUnsigned(0, 33)).toString()).equal('0');
      expect((await mathMock.minUnsigned(33, 0)).toString()).equal('0');
    });
  });

  describe('multiplyPipsByFractionUnsigned', async function () {
    it('should work for valid arguments', async () => {
      expect(
        (await mathMock.multiplyPipsByFractionSigned(1, 1, 1)).toString(),
      ).equal('1');
      expect(
        (await mathMock.multiplyPipsByFractionSigned(1, 2, 1)).toString(),
      ).equal('2');
      expect(
        (
          await mathMock.multiplyPipsByFractionSigned(
            new BigNumber(2).pow(62).toString(),
            1,
            1,
          )
        ).toString(),
      ).equal(new BigNumber(2).pow(62).toString());
    });

    it('should revert on overflow', async () => {
      await expect(
        mathMock.multiplyPipsByFractionUnsigned(
          new BigNumber(2).pow(63).toString(),
          new BigNumber(2).pow(63).toString(),
          1,
        ),
      ).to.eventually.be.rejectedWith(/pip quantity overflows uint64/i);
    });
  });

  describe('multiplyPipsByFractionSigned', async function () {
    it('should work for valid arguments', async () => {
      expect(
        (await mathMock.multiplyPipsByFractionSigned(-1, -1, -1)).toString(),
      ).equal('-1');
      expect(
        (await mathMock.multiplyPipsByFractionSigned(-1, 2, 1)).toString(),
      ).equal('-2');
      expect(
        (
          await mathMock.multiplyPipsByFractionSigned(
            new BigNumber(-2).pow(62).toString(),
            1,
            1,
          )
        ).toString(),
      ).equal(new BigNumber(-2).pow(62).toString());
    });

    it('should revert on overflow', async () => {
      await expect(
        mathMock.multiplyPipsByFractionSigned(
          new BigNumber(2).pow(62).toString(),
          new BigNumber(2).pow(62).toString(),
          1,
        ),
      ).to.eventually.be.rejectedWith(/pip quantity overflows int64/i);
    });

    it('should revert on underflow', async () => {
      await expect(
        mathMock.multiplyPipsByFractionSigned(
          new BigNumber(2).pow(62).negated().toString(),
          10000,
          1,
        ),
      ).to.eventually.be.rejectedWith(/pip quantity underflows int64/i);
    });
  });
});
