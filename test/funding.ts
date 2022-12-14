import BigNumber from 'bignumber.js';
import { expect } from 'chai';
import { ethers } from 'hardhat';

import { getPublishFundingMutipliersArguments } from '../lib';

import {
  buildFundingRates,
  buildIndexPrices,
  deployAndAssociateContracts,
  loadFundingMultipliers,
} from './helpers';

describe('Exchange', function () {
  describe('publishFundingMutipliers', async function () {
    it('should work for multiple consecutive periods', async function () {
      const [owner, dispatcher, exitFund, fee, insurance, index] =
        await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(
        owner,
        dispatcher,
        exitFund,
        fee,
        insurance,
        index,
      );

      const fundingRates = buildFundingRates(5);
      const indexPrices = await buildIndexPrices(index, 5);
      await (
        await exchange
          .connect(dispatcher)
          .publishFundingMutipliers(
            ...getPublishFundingMutipliersArguments(fundingRates, indexPrices),
          )
      ).wait();

      const fundingMultipliers = await loadFundingMultipliers(exchange);

      // 2 quartets
      expect(fundingMultipliers.length).to.equal(2);

      [...Array(5).keys()].forEach((i) =>
        expect(fundingMultipliers[Math.floor(i / 4)][i % 4]).to.equal(
          new BigNumber(fundingRates[i])
            .times(new BigNumber(indexPrices[i].price))
            .negated()
            .toString(),
        ),
      );
    });

    it('should work for multiple periods with gap', async function () {
      const [owner, dispatcher, exitFund, fee, insurance, index] =
        await ethers.getSigners();
      const { exchange } = await deployAndAssociateContracts(
        owner,
        dispatcher,
        exitFund,
        fee,
        insurance,
        index,
      );

      const fundingRates = buildFundingRates(5);
      fundingRates.splice(2, 1);
      const indexPrices = await buildIndexPrices(index, 5);
      indexPrices.splice(2, 1);

      await (
        await exchange
          .connect(dispatcher)
          .publishFundingMutipliers(
            ...getPublishFundingMutipliersArguments(fundingRates, indexPrices),
          )
      ).wait();

      const fundingMultipliers = await loadFundingMultipliers(exchange);

      // 2 quartets
      expect(fundingMultipliers.length).to.equal(2);

      [...Array(2).keys()].forEach((i) =>
        expect(fundingMultipliers[Math.floor(i / 4)][i % 4]).to.equal(
          new BigNumber(fundingRates[i])
            .times(new BigNumber(indexPrices[i].price))
            .negated()
            .toString(),
        ),
      );
      expect(fundingMultipliers[0][2]).to.equal('0');
      [...Array(2).keys()]
        .map((i) => i + 3)
        .forEach((i) =>
          expect(fundingMultipliers[Math.floor(i / 4)][i % 4]).to.equal(
            new BigNumber(fundingRates[i - 1])
              .times(new BigNumber(indexPrices[i - 1].price))
              .negated()
              .toString(),
          ),
        );
    });
  });
});
