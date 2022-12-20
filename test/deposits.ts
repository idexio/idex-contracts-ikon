import { expect } from 'chai';
import { ethers } from 'hardhat';

import { decimalToPips } from '../lib';
import { deployAndAssociateContracts, quoteAssetDecimals } from './helpers';

describe('Exchange', function () {
  describe('deposit', function () {
    it('should work', async function () {
      const [owner, dispatcher, trader, exitFund, fee, insurance, index] =
        await ethers.getSigners();
      const { exchange, usdc } = await deployAndAssociateContracts(
        owner,
        dispatcher,
        exitFund,
        fee,
        insurance,
        index,
      );

      const depositQuantity = ethers.utils.parseUnits(
        '5.0',
        quoteAssetDecimals,
      );
      await usdc.transfer(trader.address, depositQuantity);
      await usdc.connect(trader).approve(exchange.address, depositQuantity);
      await (await exchange.connect(trader).deposit(depositQuantity)).wait();

      const depositedEvents = await exchange.queryFilter(
        exchange.filters.Deposited(),
      );

      expect(depositedEvents).to.have.lengthOf(1);
      expect(depositedEvents[0].args?.quantity).to.equal(
        decimalToPips('5.00000000'),
      );
    });
  });
});
