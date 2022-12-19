import { ethers } from 'hardhat';
import { expect } from 'chai';

import { deployAndAssociateContracts } from './helpers';

describe('Exchange', function () {
  describe('setChainPropagationPeriod', async function () {
    it('should work for valid argument', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(ownerWallet);

      await exchange.connect(ownerWallet).setChainPropagationPeriod(22);

      expect(
        (await exchange.chainPropagationPeriodInBlocks()).toString(),
      ).to.equal('22');
    });

    it('should revert for argument over max', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(ownerWallet);

      let error;
      try {
        await exchange
          .connect(ownerWallet)
          .setChainPropagationPeriod('10000000000');
      } catch (e) {
        error = e;
      }
      expect(error).to.not.be.undefined;
      expect(error)
        .to.have.property('message')
        .to.match(/must be less than max/i);
    });
  });

  describe('setDelegateKeyExpirationPeriod', async function () {
    it('should work for valid argument', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(ownerWallet);

      await exchange.connect(ownerWallet).setDelegateKeyExpirationPeriod(22);

      expect(
        (await exchange.delegateKeyExpirationPeriodInMs()).toString(),
      ).to.equal('22');
    });

    it('should revert for argument over max', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(ownerWallet);

      let error;
      try {
        await exchange
          .connect(ownerWallet)
          .setDelegateKeyExpirationPeriod('100000000000000');
      } catch (e) {
        error = e;
      }
      expect(error).to.not.be.undefined;
      expect(error)
        .to.have.property('message')
        .to.match(/must be less than max/i);
    });
  });
});
