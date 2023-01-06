import BigNumber from 'bignumber.js';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import { time } from '@nomicfoundation/hardhat-network-helpers';

import {
  decimalToPips,
  fundingPeriodLengthInMs,
  getPublishFundingMutiplierArguments,
} from '../lib';

import {
  baseAssetSymbol,
  buildFundingRates,
  buildIndexPrices,
  buildIndexPrice,
  deployAndAssociateContracts,
  executeTrade,
  fundWallets,
  loadFundingMultipliers,
} from './helpers';

// FIXME Increasing the block timestamp does not seem to reset between tests
// FIXME Fix assertions to account for zero multipliers automatically added by addMarket (variable number)
describe.skip('Exchange', function () {
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

      console.log(await loadFundingMultipliers(exchange));

      const fundingRates = buildFundingRates(5);
      const indexPrices = await buildIndexPrices(index, 5);

      for (const i of [...Array(5).keys()]) {
        console.log(`Publishing ${i}`);
        console.log(indexPrices[i].timestampInMs);

        await time.increase(fundingPeriodLengthInMs / 1000);

        await (
          await exchange
            .connect(dispatcher)
            .publishFundingMutiplier(
              ...getPublishFundingMutiplierArguments(
                fundingRates[i],
                indexPrices[i],
              ),
            )
        ).wait();
      }

      const fundingMultipliers = await loadFundingMultipliers(exchange);

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

        await (
          await exchange
            .connect(dispatcher)
            .publishFundingMutiplier(
              ...getPublishFundingMutiplierArguments(
                fundingRates[i],
                indexPrices[i],
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

  describe('updateWalletFundingForMarket', async function () {
    it('should work for multiple consecutive periods', async function () {
      const [
        ownerWallet,
        dispatcherWallet,
        exitFundWallet,
        feeWallet,
        insuranceWallet,
        indexPriceCollectionServiceWallet,
        trader1Wallet,
        trader2Wallet,
      ] = await ethers.getSigners();
      const { exchange, usdc } = await deployAndAssociateContracts(
        ownerWallet,
        dispatcherWallet,
        exitFundWallet,
        feeWallet,
        insuranceWallet,
        indexPriceCollectionServiceWallet,
      );

      await usdc.connect(dispatcherWallet).faucet(dispatcherWallet.address);

      await fundWallets(
        [trader1Wallet, trader2Wallet, insuranceWallet],
        exchange,
        usdc,
      );

      const indexPrice = await buildIndexPrice(
        indexPriceCollectionServiceWallet,
      );

      await executeTrade(
        exchange,
        dispatcherWallet,
        indexPrice,
        trader1Wallet,
        trader2Wallet,
      );

      const fundingRates = buildFundingRates(5);
      const indexPrices = await buildIndexPrices(
        indexPriceCollectionServiceWallet,
        5,
      );
      for (const i of [...Array(5).keys()]) {
        await time.increase(fundingPeriodLengthInMs / 1000);

        await (
          await exchange
            .connect(dispatcherWallet)
            .publishFundingMutiplier(
              ...getPublishFundingMutiplierArguments(
                fundingRates[i],
                indexPrices[i],
              ),
            )
        ).wait();
      }

      await exchange.updateWalletFundingForMarket(
        trader1Wallet.address,
        baseAssetSymbol,
      );
    });
  });
});
