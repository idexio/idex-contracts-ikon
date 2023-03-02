import { ethers } from 'hardhat';
import { increaseTo } from '@nomicfoundation/hardhat-network-helpers/dist/src/helpers/time';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

import {
  decimalToPips,
  fundingPeriodLengthInMs,
  indexPriceToArgumentStruct,
} from '../lib';
import type { Exchange_v4 } from '../typechain-types';
import {
  addAndActivateMarket,
  baseAssetSymbol,
  buildIndexPriceWithTimestamp,
  deployAndAssociateContracts,
} from './helpers';

describe.only('Exchange', function () {
  let dispatcherWallet: SignerWithAddress;
  let exchange: Exchange_v4;
  let indexPriceServiceWallet: SignerWithAddress;

  beforeEach(async () => {
    const wallets = await ethers.getSigners();
    dispatcherWallet = wallets[1];
    indexPriceServiceWallet = wallets[4];

    const results = await deployAndAssociateContracts(
      wallets[0],
      dispatcherWallet,
      wallets[2],
      wallets[3],
      indexPriceServiceWallet,
      wallets[5],
      0,
      false,
    );
    exchange = results.exchange;

    await increaseTo(getMidnightTomorrowInSeconds());
    await addAndActivateMarket(
      results.chainlinkAggregator,
      dispatcherWallet,
      exchange,
    );
    console.log(await loadFundingMultipliers(exchange));
  });

  describe('publishFundingMultiplier', async function () {
    it('should work one funding period after initial backfill when there are no gaps', async function () {
      await increaseTo(
        getMidnightTomorrowInSeconds() + fundingPeriodLengthInMs / 1000,
      );

      const indexPrice = await buildIndexPriceWithTimestamp(
        indexPriceServiceWallet,
        (await ethers.provider.getBlock('latest')).timestamp * 1000 + 1000,
      );
      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([indexPriceToArgumentStruct(indexPrice)]);

      await exchange
        .connect(dispatcherWallet)
        .publishFundingMultiplier(baseAssetSymbol, getFundingRate());

      console.log(await loadFundingMultipliers(exchange));
    });
  });
});

const fundingRates = [
  '-0.00016100',
  '0.00026400',
  '-0.00028200',
  '-0.00005000',
  '0.00010400',
];
function getFundingRate(count = 1): string {
  return decimalToPips(fundingRates[count % fundingRates.length]);
}

function getMidnightTomorrowInSeconds(): number {
  const midnightTomorrow = new Date();
  midnightTomorrow.setHours(24, 0, 0, 0);

  return midnightTomorrow.getTime() / 1000;
}

async function loadFundingMultipliers(exchange: Exchange_v4) {
  const multipliers: string[][] = [];
  try {
    let i = 0;
    while (true) {
      multipliers.push(
        (
          await exchange.fundingMultipliersByBaseAssetSymbol(baseAssetSymbol, i)
        ).map((m) => m.toString()),
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
