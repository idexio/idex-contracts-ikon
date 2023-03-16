import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { v1 as uuidv1 } from 'uuid';
import { ethers, network } from 'hardhat';

import {
  baseAssetSymbol,
  buildIndexPrice,
  buildIndexPriceWithTimestamp,
  deployAndAssociateContracts,
  fundWallets,
  getLatestBlockTimestampInSeconds,
} from './helpers';
import {
  decimalToPips,
  fundingPeriodLengthInMs,
  getExecuteTradeArguments,
  getOrderHash,
  indexPriceToArgumentStruct,
  Order,
  OrderSide,
  OrderType,
  signatureHashVersion,
  Trade,
} from '../lib';
import type { Exchange_v4, USDC } from '../typechain-types';
import { increaseTo } from '@nomicfoundation/hardhat-network-helpers/dist/src/helpers/time';

describe.skip('Gas measurement', function () {
  let buyOrder: Order;
  let buyOrderSignature: string;
  let dispatcherWallet: SignerWithAddress;
  let exchange: Exchange_v4;
  let exitFundWallet: SignerWithAddress;
  let indexPriceServiceWallet: SignerWithAddress;
  let insuranceFundWallet: SignerWithAddress;
  let ownerWallet: SignerWithAddress;
  let sellOrder: Order;
  let sellOrderSignature: string;
  let trade: Trade;
  let trader1Wallet: SignerWithAddress;
  let trader2Wallet: SignerWithAddress;
  let usdc: USDC;

  before(async () => {
    await network.provider.send('hardhat_reset');
  });

  beforeEach(async () => {
    const wallets = await ethers.getSigners();

    const [feeWallet] = wallets;
    [
      ,
      dispatcherWallet,
      exitFundWallet,
      indexPriceServiceWallet,
      insuranceFundWallet,
      ownerWallet,
      trader1Wallet,
      trader2Wallet,
    ] = wallets;
    const results = await deployAndAssociateContracts(
      ownerWallet,
      dispatcherWallet,
      exitFundWallet,
      feeWallet,
      indexPriceServiceWallet,
      insuranceFundWallet,
    );
    exchange = results.exchange;
    usdc = results.usdc;

    await usdc.faucet(dispatcherWallet.address);

    await fundWallets(
      [trader1Wallet, trader2Wallet],
      exchange,
      results.usdc,
      '100000.00000000',
    );

    await exchange
      .connect(dispatcherWallet)
      .publishIndexPrices([
        indexPriceToArgumentStruct(
          await buildIndexPrice(indexPriceServiceWallet),
        ),
      ]);

    buyOrder = {
      signatureHashVersion,
      nonce: uuidv1(),
      wallet: trader2Wallet.address,
      market: `${baseAssetSymbol}-USD`,
      type: OrderType.Limit,
      side: OrderSide.Buy,
      quantity: '10.00000000',
      price: '2000.00000000',
    };
    buyOrderSignature = await trader2Wallet.signMessage(
      ethers.utils.arrayify(getOrderHash(buyOrder)),
    );

    sellOrder = {
      signatureHashVersion,
      nonce: uuidv1(),
      wallet: trader1Wallet.address,
      market: `${baseAssetSymbol}-USD`,
      type: OrderType.Limit,
      side: OrderSide.Sell,
      quantity: '10.00000000',
      price: '2000.00000000',
    };
    sellOrderSignature = await trader1Wallet.signMessage(
      ethers.utils.arrayify(getOrderHash(sellOrder)),
    );

    trade = {
      baseAssetSymbol: baseAssetSymbol,
      baseQuantity: '10.00000000',
      quoteQuantity: '20000.00000000',
      makerFeeQuantity: '20.00000000',
      takerFeeQuantity: '40.00000000',
      price: '2000.00000000',
      makerSide: OrderSide.Sell,
    };

    await exchange
      .connect(dispatcherWallet)
      .executeTrade(
        ...getExecuteTradeArguments(
          buyOrder,
          buyOrderSignature,
          sellOrder,
          sellOrderSignature,
          trade,
        ),
      );

    buyOrder.nonce = uuidv1();
    buyOrderSignature = await trader2Wallet.signMessage(
      ethers.utils.arrayify(getOrderHash(buyOrder)),
    );

    sellOrder.nonce = uuidv1();
    sellOrderSignature = await trader1Wallet.signMessage(
      ethers.utils.arrayify(getOrderHash(sellOrder)),
    );
  });

  describe('trades', async function () {
    it('with no outstanding funding payments (limit-market)', async () => {
      buyOrder.type = OrderType.Market;
      buyOrder.price = '0.00000000';
      buyOrderSignature = await trader2Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(buyOrder)),
      );

      const result = await exchange
        .connect(dispatcherWallet)
        .executeTrade(
          ...getExecuteTradeArguments(
            buyOrder,
            buyOrderSignature,
            sellOrder,
            sellOrderSignature,
            trade,
          ),
        );
      console.log((await result.wait()).gasUsed.toString());
    });

    it('with no outstanding funding payments (limit-limit)', async () => {
      const result = await exchange
        .connect(dispatcherWallet)
        .executeTrade(
          ...getExecuteTradeArguments(
            buyOrder,
            buyOrderSignature,
            sellOrder,
            sellOrderSignature,
            trade,
          ),
        );
      console.log((await result.wait()).gasUsed.toString());
    });

    it('with 1 outstanding funding payments', async () => {
      await publishFundingRates(
        exchange,
        dispatcherWallet,
        indexPriceServiceWallet,
        10,
      );

      const result = await exchange
        .connect(dispatcherWallet)
        .executeTrade(
          ...getExecuteTradeArguments(
            buyOrder,
            buyOrderSignature,
            sellOrder,
            sellOrderSignature,
            trade,
          ),
        );
      console.log((await result.wait()).gasUsed.toString());
    });

    it('with 10 outstanding funding payments', async () => {
      await publishFundingRates(
        exchange,
        dispatcherWallet,
        indexPriceServiceWallet,
        10,
      );

      const result = await exchange
        .connect(dispatcherWallet)
        .executeTrade(
          ...getExecuteTradeArguments(
            buyOrder,
            buyOrderSignature,
            sellOrder,
            sellOrderSignature,
            trade,
          ),
        );
      console.log((await result.wait()).gasUsed.toString());
    });

    it('with 100 outstanding funding payments', async () => {
      await publishFundingRates(
        exchange,
        dispatcherWallet,
        indexPriceServiceWallet,
        100,
      );

      const result = await exchange
        .connect(dispatcherWallet)
        .executeTrade(
          ...getExecuteTradeArguments(
            buyOrder,
            buyOrderSignature,
            sellOrder,
            sellOrderSignature,
            trade,
          ),
        );
      console.log((await result.wait()).gasUsed.toString());
    });

    it('with 1000 outstanding funding payments', async () => {
      await publishFundingRates(
        exchange,
        dispatcherWallet,
        indexPriceServiceWallet,
        1000,
      );

      const result = await exchange
        .connect(dispatcherWallet)
        .executeTrade(
          ...getExecuteTradeArguments(
            buyOrder,
            buyOrderSignature,
            sellOrder,
            sellOrderSignature,
            trade,
          ),
        );
      console.log((await result.wait()).gasUsed.toString());
    });

    it('with 6000 outstanding funding payments', async () => {
      await publishFundingRates(
        exchange,
        dispatcherWallet,
        indexPriceServiceWallet,
        6000,
      );

      const result = await exchange
        .connect(dispatcherWallet)
        .executeTrade(
          ...getExecuteTradeArguments(
            buyOrder,
            buyOrderSignature,
            sellOrder,
            sellOrderSignature,
            trade,
          ),
        );
      console.log((await result.wait()).gasUsed.toString());
    });
  });
});

async function publishFundingRates(
  exchange: Exchange_v4,
  dispatcherWallet: SignerWithAddress,
  indexPriceServiceWallet: SignerWithAddress,
  count: number,
) {
  const startTimestampInMs = (await getLatestBlockTimestampInSeconds()) * 1000;

  for (let i = 1; i <= count; i++) {
    const nextFundingTimestampInMs =
      startTimestampInMs + i * fundingPeriodLengthInMs;

    await increaseTo(nextFundingTimestampInMs / 1000);

    await exchange
      .connect(dispatcherWallet)
      .publishIndexPrices([
        indexPriceToArgumentStruct(
          await buildIndexPriceWithTimestamp(
            indexPriceServiceWallet,
            nextFundingTimestampInMs,
          ),
        ),
      ]);

    await exchange
      .connect(dispatcherWallet)
      .publishFundingMultiplier(
        baseAssetSymbol,
        decimalToPips(getFundingRate()),
      );
  }
}

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
