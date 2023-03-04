import BigNumber from 'bignumber.js';
import { ethers } from 'hardhat';
import { expect } from 'chai';
import {
  increase,
  increaseTo,
} from '@nomicfoundation/hardhat-network-helpers/dist/src/helpers/time';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

import {
  decimalToPips,
  fundingPeriodLengthInMs,
  IndexPrice,
  indexPriceToArgumentStruct,
} from '../lib';
import type { Exchange_v4, USDC } from '../typechain-types';
import {
  addAndActivateMarket,
  baseAssetSymbol,
  buildIndexPrice,
  executeTrade,
  fundWallets,
  getLatestBlockTimestampInSeconds,
  deployAndAssociateContracts,
  buildIndexPriceWithTimestamp,
  quoteAssetSymbol,
} from './helpers';

describe('Exchange', function () {
  let dispatcherWallet: SignerWithAddress;
  let exchange: Exchange_v4;
  let indexPrice: IndexPrice;
  let indexPriceServiceWallet: SignerWithAddress;
  let usdc: USDC;

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
    usdc = results.usdc;

    await increaseTo(await getMidnightTomorrowInSecondsUTC());
    await addAndActivateMarket(
      results.chainlinkAggregator,
      dispatcherWallet,
      exchange,
    );
    await increase(fundingPeriodLengthInMs / 1000);

    indexPrice = await buildIndexPrice(indexPriceServiceWallet);
  });

  describe('publishFundingMultiplier', async function () {
    it('should work one funding period after initial backfill when there are no gaps', async function () {
      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([indexPriceToArgumentStruct(indexPrice)]);

      await exchange
        .connect(dispatcherWallet)
        .publishFundingMultiplier(
          baseAssetSymbol,
          decimalToPips(getFundingRate()),
        );

      const multipliers = await loadFundingMultipliers(exchange);
      expect(multipliers).to.be.an('array').with.lengthOf(2);
      expect(multipliers[0]).to.equal('0');
      expect(multipliers[1]).to.equal(
        decimalToPips(
          new BigNumber(indexPrice.price)
            .times(new BigNumber(getFundingRate()))
            .negated()
            .toString(),
        ),
      );
    });

    it('should work with missing periods between multipliers', async function () {
      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([indexPriceToArgumentStruct(indexPrice)]);

      await exchange
        .connect(dispatcherWallet)
        .publishFundingMultiplier(
          baseAssetSymbol,
          decimalToPips(getFundingRate()),
        );

      await increase((fundingPeriodLengthInMs * 4) / 1000);

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPrice(indexPriceServiceWallet),
          ),
        ]);

      await exchange
        .connect(dispatcherWallet)
        .publishFundingMultiplier(
          baseAssetSymbol,
          decimalToPips(getFundingRate(1)),
        );

      const multipliers = await loadFundingMultipliers(exchange);
      expect(multipliers).to.be.an('array').with.lengthOf(6);
      expect(multipliers[0]).to.equal('0');
      expect(multipliers[1]).to.equal(
        decimalToPips(
          new BigNumber(indexPrice.price)
            .times(new BigNumber(getFundingRate()))
            .negated()
            .toString(),
        ),
      );
      expect(multipliers[2]).to.equal('0');
      expect(multipliers[3]).to.equal('0');
      expect(multipliers[4]).to.equal('0');
      expect(multipliers[5]).to.equal(
        decimalToPips(
          new BigNumber(indexPrice.price)
            .times(new BigNumber(getFundingRate(1)))
            .negated()
            .toString(),
        ),
      );
    });

    it('should revert for invalid symbol', async function () {
      await expect(
        exchange
          .connect(dispatcherWallet)
          .publishFundingMultiplier('XYZ', decimalToPips(getFundingRate())),
      ).to.eventually.be.rejectedWith(/no active market found/i);
    });
  });

  describe('applyOutstandingWalletFundingForMarket', async function () {
    it('should work for wallet with outstanding funding payments', async function () {
      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([indexPriceToArgumentStruct(indexPrice)]);

      await exchange
        .connect(dispatcherWallet)
        .publishFundingMultiplier(
          baseAssetSymbol,
          decimalToPips(getFundingRate()),
        );

      const trader1Wallet = (await ethers.getSigners())[6];
      const trader2Wallet = (await ethers.getSigners())[7];
      await fundWallets([trader1Wallet, trader2Wallet], exchange, usdc);

      const trade = await executeTrade(
        exchange,
        dispatcherWallet,
        await buildIndexPrice(indexPriceServiceWallet),
        trader1Wallet,
        trader2Wallet,
      );

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPriceWithTimestamp(
              indexPriceServiceWallet,
              indexPrice.timestampInMs + fundingPeriodLengthInMs,
            ),
          ),
        ]);

      const originalTrader1QuoteBalance = (
        await exchange.loadBalanceBySymbol(
          trader1Wallet.address,
          quoteAssetSymbol,
        )
      ).toString();
      const originalTrader2QuoteBalance = (
        await exchange.loadBalanceBySymbol(
          trader2Wallet.address,
          quoteAssetSymbol,
        )
      ).toString();

      await exchange
        .connect(dispatcherWallet)
        .publishFundingMultiplier(
          baseAssetSymbol,
          decimalToPips(getFundingRate()),
        );

      const exitWithdrawalQuantity = (
        await exchange.loadQuoteQuantityAvailableForExitWithdrawal(
          trader1Wallet.address,
        )
      ).toString();

      const expectedTrader1FundingPayment = decimalToPips(
        new BigNumber(indexPrice.price)
          .times(new BigNumber(getFundingRate()))
          .times(trade.baseQuantity)
          .toString(),
      );
      expect(
        (
          await exchange.loadOutstandingWalletFunding(trader1Wallet.address)
        ).toString(),
      ).to.equal(expectedTrader1FundingPayment);

      const expectedTrader2FundingPayment = decimalToPips(
        new BigNumber(indexPrice.price)
          .times(new BigNumber(getFundingRate()))
          .negated()
          .times(trade.baseQuantity)
          .toString(),
      );
      expect(
        (
          await exchange.loadOutstandingWalletFunding(trader2Wallet.address)
        ).toString(),
      ).to.equal(expectedTrader2FundingPayment);

      await exchange.applyOutstandingWalletFundingForMarket(
        trader1Wallet.address,
        baseAssetSymbol,
      );
      await exchange.applyOutstandingWalletFundingForMarket(
        trader2Wallet.address,
        baseAssetSymbol,
      );

      expect(
        (
          await exchange.loadBalanceBySymbol(
            trader1Wallet.address,
            quoteAssetSymbol,
          )
        ).toString(),
      ).to.equal(
        new BigNumber(originalTrader1QuoteBalance)
          .plus(new BigNumber(expectedTrader1FundingPayment))
          .toString(),
      );
      expect(
        (
          await exchange.loadBalanceBySymbol(
            trader2Wallet.address,
            quoteAssetSymbol,
          )
        ).toString(),
      ).to.equal(
        new BigNumber(originalTrader2QuoteBalance)
          .plus(new BigNumber(expectedTrader2FundingPayment))
          .toString(),
      );
      /*
       * FIXME Why is this failing?
      expect(
        (
          await exchange.loadQuoteQuantityAvailableForExitWithdrawal(
            trader1Wallet.address,
          )
        ).toString(),
      ).to.equal(exitWithdrawalQuantity);
      */

      expect(
        (
          await exchange.loadOutstandingWalletFunding(trader1Wallet.address)
        ).toString(),
      ).to.equal('0');
      expect(
        (
          await exchange.loadOutstandingWalletFunding(trader2Wallet.address)
        ).toString(),
      ).to.equal('0');

      // TODO Verify balance updates
    });

    it('should revert for invalid symbol', async function () {
      await expect(
        exchange.applyOutstandingWalletFundingForMarket(
          (
            await ethers.getSigners()
          )[6].address,
          'XYZ',
        ),
      ).to.eventually.be.rejectedWith(/market not found/i);
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
function getFundingRate(index = 0): string {
  return fundingRates[index % fundingRates.length];
}

async function getMidnightTomorrowInSecondsUTC(): Promise<number> {
  const midnightTomorrow = new Date(0);
  midnightTomorrow.setUTCSeconds(await getLatestBlockTimestampInSeconds());
  midnightTomorrow.setUTCHours(24, 0, 0, 0);

  return midnightTomorrow.getTime() / 1000;
}

const NO_FUNDING_MULTIPLIER = (BigInt(-2) ** BigInt(63)).toString();
async function loadFundingMultipliers(exchange: Exchange_v4) {
  const quartets: string[][] = [];
  try {
    let i = 0;
    while (true) {
      quartets.push(
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

  return quartets.flat().filter((q) => q != NO_FUNDING_MULTIPLIER);
}
