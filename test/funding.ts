import BigNumber from 'bignumber.js';
import { ethers } from 'hardhat';
import { time } from '@nomicfoundation/hardhat-network-helpers';

import {
  decimalToPips,
  fundingPeriodLengthInMs,
  getPublishFundingMutiplierArguments,
  indexPriceToArgumentStruct,
} from '../lib';

import {
  baseAssetSymbol,
  buildFundingRates,
  buildIndexPrices,
  buildIndexPrice,
  deployAndAssociateContracts,
  executeTrade,
  expect,
  fundWallets,
  loadFundingMultipliers,
} from './helpers';

import { FundingMultipliersMock } from '../typechain-types';

export async function loadFundingMultipliersFromMock(
  fundingMultipliersMock: FundingMultipliersMock,
) {
  const multipliers: string[][] = [];
  try {
    let i = 0;
    while (true) {
      multipliers.push(
        (await fundingMultipliersMock.fundingMultipliers(i)).map((m) =>
          m.toString(),
        ),
      );

      i += 1;
    }
  } catch (e) {
    if (e instanceof Error && !e.message.match(/^call revert exception/)) {
      console.error(e.message);
    }
  }

  return multipliers;
}

// FIXME Increasing the block timestamp does not seem to reset between tests
// FIXME Fix assertions to account for zero multipliers automatically added by addMarket (variable number)
describe('Exchange', function () {
  describe.skip('publishFundingMutipliers', async function () {
    it('should work for multiple consecutive periods', async function () {
      const fundingMultipliersMock = await (
        await ethers.getContractFactory('FundingMultipliersMock')
      ).deploy();

      for (const i of [...Array(6).keys()]) {
        await fundingMultipliersMock.publishFundingMultipler(1);
      }

      console.log(await loadFundingMultipliersFromMock(fundingMultipliersMock));

      const midnight = 1673913600000;

      await expect(
        fundingMultipliersMock.loadAggregateMultiplier(
          midnight - fundingPeriodLengthInMs * 3,
          midnight,
          midnight,
        ),
      ).to.eventually.equal('4');
    });
  });

  describe.skip('publishFundingMutipliers', async function () {
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

      for (const i of [...Array(5).keys()]) {
        console.log(`Publishing ${i}`);
        console.log(indexPrices[i].timestampInMs);

        await time.increase(fundingPeriodLengthInMs / 1000);

        await exchange
          .connect(dispatcher)
          .publishIndexPrices([indexPriceToArgumentStruct(indexPrices[i])]);

        await exchange
          .connect(dispatcher)
          .publishFundingMultiplier(
            ...getPublishFundingMutiplierArguments(
              baseAssetSymbol,
              fundingRates[i],
            ),
          );
      }

      const fundingMultipliers = await loadFundingMultipliers(exchange);

      console.log(fundingMultipliers);

      /*
      // 2 quartets
      expect(fundingMultipliers.length).to.equal(2);

      [...Array(5).keys()].forEach((i) =>
        expect(fundingMultipliers[Math.floor(i / 4)][i % 4]).to.equal(
          decimalToPips(
            new BigNumber(fundingRates[i])
              .times(new BigNumber(indexPrices[i].price))
              .negated()
              .toString(),
          ),
        ),
      );
      */
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

      for (const i of [...Array(4).keys()]) {
        console.log(`Publishing ${i}`);
        await time.increase(fundingPeriodLengthInMs / 1000);

        await exchange
          .connect(dispatcher)
          .publishIndexPrices([indexPriceToArgumentStruct(indexPrices[i])]);

        await (
          await exchange
            .connect(dispatcher)
            .publishFundingMultiplier(
              ...getPublishFundingMutiplierArguments(
                baseAssetSymbol,
                fundingRates[i],
              ),
            )
        ).wait();
      }

      const fundingMultipliers = await loadFundingMultipliers(exchange);

      // 2 quartets
      expect(fundingMultipliers.length).to.equal(2);

      [...Array(2).keys()].forEach((i) =>
        expect(fundingMultipliers[Math.floor(i / 4)][i % 4]).to.equal(
          decimalToPips(
            new BigNumber(fundingRates[i])
              .times(new BigNumber(indexPrices[i].price))
              .negated()
              .toString(),
          ),
        ),
      );
      expect(fundingMultipliers[0][2]).to.equal('0');
      [...Array(2).keys()]
        .map((i) => i + 3)
        .forEach((i) =>
          expect(fundingMultipliers[Math.floor(i / 4)][i % 4]).to.equal(
            decimalToPips(
              new BigNumber(fundingRates[i - 1])
                .times(new BigNumber(indexPrices[i - 1].price))
                .negated()
                .toString(),
            ),
          ),
        );
    });
  });

  describe.skip('updateWalletFundingForMarket', async function () {
    it('should work for multiple consecutive periods', async function () {
      const [
        ownerWallet,
        dispatcherWallet,
        exitFundWallet,
        feeWallet,
        insuranceWallet,
        indexPriceServiceWallet,
        trader1Wallet,
        trader2Wallet,
      ] = await ethers.getSigners();
      const { exchange, usdc } = await deployAndAssociateContracts(
        ownerWallet,
        dispatcherWallet,
        exitFundWallet,
        feeWallet,
        insuranceWallet,
        indexPriceServiceWallet,
      );

      await usdc.connect(dispatcherWallet).faucet(dispatcherWallet.address);

      await fundWallets(
        [trader1Wallet, trader2Wallet, insuranceWallet],
        exchange,
        usdc,
      );

      const indexPrice = await buildIndexPrice(indexPriceServiceWallet);

      await executeTrade(
        exchange,
        dispatcherWallet,
        indexPrice,
        trader1Wallet,
        trader2Wallet,
      );

      const fundingRates = buildFundingRates(5);
      const indexPrices = await buildIndexPrices(indexPriceServiceWallet, 5);
      for (const i of [...Array(5).keys()]) {
        await time.increase(fundingPeriodLengthInMs / 1000);

        await exchange
          .connect(dispatcherWallet)
          .publishIndexPrices([indexPriceToArgumentStruct(indexPrices[i])]);

        await exchange
          .connect(dispatcherWallet)
          .publishFundingMultiplier(
            ...getPublishFundingMutiplierArguments(
              baseAssetSymbol,
              fundingRates[i],
            ),
          );
      }

      await exchange.updateWalletFundingForMarket(
        trader1Wallet.address,
        baseAssetSymbol,
      );
    });
  });
});
