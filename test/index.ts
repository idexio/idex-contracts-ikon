import BigNumber from 'bn.js';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import { v1 as uuidv1 } from 'uuid';

import {
  decimalToPips,
  getDelegatedKeyAuthorizationMessage,
  getExecuteOrderBookTradeArguments,
  getOrderHash,
  getWithdrawalHash,
  getWithdrawArguments,
  LiquidationType,
  Order,
  OrderSide,
  OrderType,
  signatureHashVersion,
  Trade,
} from '../lib';

import {
  buildFundingRates,
  buildLimitOrder,
  buildIndexPrice,
  buildIndexPrices,
  buildIndexPriceWithValue,
  quoteAssetDecimals,
  deployAndAssociateContracts,
  fundWallets,
  logWalletBalances,
} from './helpers';

describe('Exchange', function () {
  it('deposit and withdraw should work', async function () {
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

    const depositQuantity = ethers.utils.parseUnits('5.0', quoteAssetDecimals);
    await usdc.transfer(trader.address, depositQuantity);
    await usdc.connect(trader).approve(exchange.address, depositQuantity);
    await (await exchange.connect(trader).deposit(depositQuantity)).wait();

    const depositedEvents = await exchange.queryFilter(
      exchange.filters.Deposited(),
    );

    expect(depositedEvents.length).to.equal(1);
    expect(depositedEvents[0].args?.quantityInPips).to.equal(
      decimalToPips('5.00000000'),
    );

    const withdrawal = {
      nonce: uuidv1(),
      wallet: trader.address,
      quantity: '1.00000000',
    };
    const signature = await trader.signMessage(
      ethers.utils.arrayify(getWithdrawalHash(withdrawal)),
    );
    await (
      await exchange
        .connect(dispatcher)
        .withdraw(
          ...getWithdrawArguments(withdrawal, '0.00000000', signature, [
            await buildIndexPrice(index),
          ]),
        )
    ).wait();

    const withdrawal2 = {
      nonce: uuidv1(),
      wallet: trader.address,
      quantity: '1.00000000',
    };
    const signature2 = await trader.signMessage(
      ethers.utils.arrayify(getWithdrawalHash(withdrawal2)),
    );
    await (
      await exchange
        .connect(dispatcher)
        .withdraw(
          ...getWithdrawArguments(withdrawal2, '0.00000000', signature2, [
            await buildIndexPrice(index),
          ]),
        )
    ).wait();

    const withdrawnEvents = await exchange.queryFilter(
      exchange.filters.Withdrawn(),
    );
    expect(withdrawnEvents.length).to.equal(2);
    expect(withdrawnEvents.length).to.equal(2);
    expect(withdrawnEvents[0].args?.quantityInPips).to.equal(
      decimalToPips('1.00000000'),
    );
  });

  it('publishFundingMutipliers should work', async function () {
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

    await (
      await exchange
        .connect(dispatcher)
        .publishFundingMutipliers(
          buildFundingRates(5),
          await buildIndexPrices(index, 5),
        )
    ).wait();
  });

  describe('executeOrderBookTrade', async function () {
    it('should work with maker rebate', async function () {
      const [
        owner,
        dispatcher,
        exitFund,
        fee,
        insurance,
        index,
        trader1,
        trader2,
      ] = await ethers.getSigners();
      const { exchange, usdc } = await deployAndAssociateContracts(
        owner,
        dispatcher,
        exitFund,
        fee,
        insurance,
        index,
      );

      await fundWallets([trader1, trader2], exchange, usdc);

      const { order: buyOrder, signature: buyOrderSignature } =
        await buildLimitOrder(
          trader1,
          OrderSide.Buy,
          'ETH-USDC',
          '1.00000000',
          '2000.00000000',
        );
      const { order: sellOrder, signature: sellOrderSignature } =
        await buildLimitOrder(
          trader2,
          OrderSide.Sell,
          'ETH-USDC',
          '1.00000000',
          '2000.00000000',
        );

      const trade: Trade = {
        baseAssetSymbol: 'ETH',
        quoteAssetSymbol: 'USD',
        baseQuantity: '1.00000000',
        quoteQuantity: '2000.00000000',
        makerFeeQuantity: '-2.00000000',
        takerFeeQuantity: '4.00000000',
        price: '1.00000000',
        makerSide: OrderSide.Sell,
      };

      const indexPrice = await buildIndexPrice(index);

      await (
        await exchange
          .connect(dispatcher)
          .executeOrderBookTrade(
            ...getExecuteOrderBookTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
              [indexPrice],
              [indexPrice],
            ),
          )
      ).wait();

      console.log('Trader1');
      await logWalletBalances(trader1.address, exchange, [indexPrice]);

      console.log('Trader2');
      await logWalletBalances(trader2.address, exchange, [indexPrice]);
    });

    it.only('can haz deebug', async function () {
      const [
        owner,
        dispatcher,
        exitFund,
        fee,
        insurance,
        index,
        trader1,
        trader2,
        trader1Delegate,
      ] = await ethers.getSigners();
      const { custodian, exchange, usdc } = await deployAndAssociateContracts(
        owner,
        dispatcher,
        exitFund,
        fee,
        insurance,
        index,
      );

      await usdc.connect(dispatcher).faucet(dispatcher.address);

      await fundWallets([trader1, trader2], exchange, usdc);

      await (await exchange.setDelegateKeyExpirationPeriod(10000000)).wait();

      const trader1DelegatedKeyAuthorization = {
        delegatedPublicKey: trader1Delegate.address,
        nonce: uuidv1({ msecs: new Date().getTime() - 1000 }),
      };

      const trader1DelegatedKeyAuthorizationSignature =
        await trader1.signMessage(
          getDelegatedKeyAuthorizationMessage(trader1DelegatedKeyAuthorization),
        );
      const sellDelegatedKeyAuthorization = {
        ...trader1DelegatedKeyAuthorization,
        signature: trader1DelegatedKeyAuthorizationSignature,
      };

      const sellOrder: Order = {
        signatureHashVersion,
        nonce: uuidv1({ msecs: new Date().getTime() - 100 * 60 * 60 * 1000 }),
        wallet: trader1.address,
        delegatedPublicKey: sellDelegatedKeyAuthorization.delegatedPublicKey,
        market: 'ETH-USDC',
        type: OrderType.Limit,
        side: OrderSide.Sell,
        quantity: '10.00000000',
        price: '2000.00000000',
      };
      const sellOrderSignature = await trader1Delegate.signMessage(
        ethers.utils.arrayify(getOrderHash(sellOrder)),
      );

      const buyOrder: Order = {
        signatureHashVersion,
        nonce: uuidv1({ msecs: new Date().getTime() - 100 * 60 * 60 * 1000 }),
        wallet: trader2.address,
        market: 'ETH-USDC',
        type: OrderType.Limit,
        side: OrderSide.Buy,
        quantity: '10.00000000',
        price: '2000.00000000',
      };
      const buyOrderSignature = await trader2.signMessage(
        ethers.utils.arrayify(getOrderHash(buyOrder)),
      );

      const trade: Trade = {
        baseAssetSymbol: 'ETH',
        quoteAssetSymbol: 'USD',
        baseQuantity: '10.00000000',
        quoteQuantity: '20000.00000000',
        makerFeeQuantity: '20.00000000',
        takerFeeQuantity: '40.00000000',
        price: '2000.00000000',
        makerSide: OrderSide.Sell,
      };

      const indexPrice = await buildIndexPrice(index);

      /*
      await (
        await exchange.setMarketOverrides(
          trader1.address,
          'ETH',
          '10000000',
          '3000000',
          '1000000',
          '14000000000',
          '2800000000',
          '282000000000',
        )
      ).wait();
      */

      await (
        await exchange
          .connect(dispatcher)
          .executeOrderBookTrade(
            ...getExecuteOrderBookTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
              [indexPrice],
              [indexPrice],
              undefined,
              sellDelegatedKeyAuthorization,
            ),
          )
      ).wait();

      /*
      await (
        await exchange.connect(dispatcher).deactivateMarket('ETH', indexPrice)
      ).wait();

      await (
        await exchange
          .connect(dispatcher)
          .liquidatePositionInDeactivatedMarket(
            'ETH',
            trader1.address,
            decimalToPips('-20000.00000000'),
            [indexPrice],
          )
      ).wait();
      */

      /*
    const withdrawal = {
      nonce: uuidv1(),
      wallet: trader1.address,
      quantity: '1.00000000',
    };
    const signature = await trader1.signMessage(
      ethers.utils.arrayify(getWithdrawalHash(withdrawal)),
    );
    await (
      await exchange
        .connect(dispatcher)
        .withdraw(
          ...getWithdrawArguments(withdrawal, '0.01000000', signature, [
            await buildIndexPrice(index),
          ]),
        )
    ).wait();

      await (
        await exchange
          .connect(dispatcher)
          .publishFundingMutipliers(
            await buildIndexPrices(index, 50),
            buildFundingRates(50),
          )
      ).wait();

      const withdrawal2 = {
        nonce: uuidv1(),
        wallet: trader1.address,
        quantity: '1.00000000',
      };
      const signature2 = await trader1.signMessage(
        ethers.utils.arrayify(getWithdrawalHash(withdrawal2)),
      );
      await (
        await exchange
          .connect(dispatcher)
          .withdraw(
            ...getWithdrawArguments(withdrawal2, '0.01000000', signature2, [
              await buildIndexPrice(index),
            ]),
          )
      ).wait();*/

      console.log('Trader1');
      await logWalletBalances(trader1.address, exchange, [indexPrice]);

      console.log('Trader2');
      await logWalletBalances(trader2.address, exchange, [indexPrice]);

      console.log(await usdc.balanceOf(custodian.address));

      await exchange.connect(trader2).exitWallet();
      await exchange.withdrawExit(trader2.address);

      console.log('Trader1');
      await logWalletBalances(trader1.address, exchange, [indexPrice]);

      console.log('Trader2');
      await logWalletBalances(trader2.address, exchange, [indexPrice]);

      console.log(await usdc.balanceOf(custodian.address));

      //console.log(await usdc.balanceOf(custodian.address));
      /*
      const sellOrder2: Order = {
        signatureHashVersion,
        nonce: uuidv1(),
        wallet: trader1.address,
        market: 'ETH-USDC',
        type: OrderType.Limit,
        side: OrderSide.Sell,
        quantity: '1.00000000',
        price: '2000.00000000',
      };
      const sellOrderSignature2 = await trader1Delegate.signMessage(
        ethers.utils.arrayify(
          getOrderHash(sellOrder2, sellDelegatedKeyAuthorization),
        ),
      );

      const buyOrder2: Order = {
        signatureHashVersion,
        nonce: uuidv1(),
        wallet: trader2.address,
        market: 'ETH-USDC',
        type: OrderType.Limit,
        side: OrderSide.Buy,
        quantity: '1.00000000',
        price: '2000.00000000',
      };
      const buyOrderSignature2 = await trader2.signMessage(
        ethers.utils.arrayify(getOrderHash(buyOrder2)),
      );

      const trade2: Trade = {
        baseAssetSymbol: 'ETH',
        quoteAssetSymbol: 'USD',
        baseQuantity: '1.00000000',
        quoteQuantity: '2000.00000000',
        makerFeeQuantity: '2.00000000',
        takerFeeQuantity: '4.00000000',
        price: '1.00000000',
        makerSide: OrderSide.Sell,
      };

      await (
        await exchange
          .connect(dispatcher)
          .executeOrderBookTrade(
            ...getExecuteOrderBookTradeArguments(
              buyOrder2,
              buyOrderSignature2,
              sellOrder2,
              sellOrderSignature2,
              trade2,
              [indexPrice],
              undefined,
              sellDelegatedKeyAuthorization,
            ),
          )
      ).wait();

      console.log('Trader1');
      await logWalletBalances(trader1.address, exchange, [indexPrice]);

      console.log('Trader2');
      await logWalletBalances(trader2.address, exchange, [indexPrice]);
    });
    */
    });
  });

  describe('liquidationAcquisitionDeleverage', async function () {
    it('can haz diibug', async function () {
      const [
        owner,
        dispatcher,
        exitFund,
        fee,
        insuranceFund,
        index,
        trader1,
        trader2,
      ] = await ethers.getSigners();
      const { chainlinkAggregator, usdc, exchange } =
        await deployAndAssociateContracts(
          owner,
          dispatcher,
          exitFund,
          fee,
          insuranceFund,
          index,
        );

      (
        await exchange.addMarket({
          exists: true,
          isActive: false,
          baseAssetSymbol: 'BTC',
          chainlinkPriceFeedAddress: chainlinkAggregator.address,
          initialMarginFractionInPips: '5000000',
          maintenanceMarginFractionInPips: '3000000',
          incrementalInitialMarginFractionInPips: '1000000',
          baselinePositionSizeInPips: '14000000000',
          incrementalPositionSizeInPips: '2800000000',
          maximumPositionSizeInPips: '282000000000',
          minimumPositionSizeInPips: '2000000000',
          lastIndexPriceTimestampInMs: 0,
          indexPriceInPipsAtDeactivation: 0,
        })
      ).wait();
      (await exchange.connect(dispatcher).activateMarket('BTC')).wait();

      await fundWallets([trader1, trader2, insuranceFund], exchange, usdc);

      const { order: buyOrder, signature: buyOrderSignature } =
        await buildLimitOrder(
          trader1,
          OrderSide.Buy,
          'ETH-USDC',
          '1.00000000',
          '2000.00000000',
        );
      const { order: sellOrder, signature: sellOrderSignature } =
        await buildLimitOrder(
          trader2,
          OrderSide.Sell,
          'ETH-USDC',
          '1.00000000',
          '2000.00000000',
        );

      const trade: Trade = {
        baseAssetSymbol: 'ETH',
        quoteAssetSymbol: 'USD',
        baseQuantity: '1.00000000',
        quoteQuantity: '2000.00000000',
        makerFeeQuantity: '2.00000000',
        takerFeeQuantity: '4.00000000',
        price: buyOrder.price,
        makerSide: OrderSide.Sell,
      };

      const indexPrices = await Promise.all([
        buildIndexPrice(index),
        buildIndexPriceWithValue(index, '30000000000', 'BTC'),
      ]);

      await (
        await exchange
          .connect(dispatcher)
          .executeOrderBookTrade(
            ...getExecuteOrderBookTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
              indexPrices,
              indexPrices,
            ),
          )
      ).wait();

      const { order: buyOrder2, signature: buyOrderSignature2 } =
        await buildLimitOrder(
          trader1,
          OrderSide.Buy,
          'BTC-USDC',
          '1.00000000',
          '30000.00000000',
        );
      const { order: sellOrder2, signature: sellOrderSignature2 } =
        await buildLimitOrder(
          trader2,
          OrderSide.Sell,
          'BTC-USDC',
          '1.00000000',
          '30000.00000000',
        );
      console.log('--- ABOVE WATER ---');
      console.log('Trader1');
      await logWalletBalances(trader1.address, exchange, indexPrices);

      const trade2: Trade = {
        baseAssetSymbol: 'BTC',
        quoteAssetSymbol: 'USD',
        baseQuantity: '1.00000000',
        quoteQuantity: '30000.00000000',
        makerFeeQuantity: '30.00000000',
        takerFeeQuantity: '50.00000000',
        price: buyOrder.price,
        makerSide: OrderSide.Sell,
      };

      await (
        await exchange
          .connect(dispatcher)
          .executeOrderBookTrade(
            ...getExecuteOrderBookTradeArguments(
              buyOrder2,
              buyOrderSignature2,
              sellOrder2,
              sellOrderSignature2,
              trade2,
              indexPrices,
              indexPrices,
            ),
          )
      ).wait();

      console.log('--- ABOVE WATER ---');
      console.log('Trader1');
      await logWalletBalances(trader1.address, exchange, indexPrices);

      const newIndexLowPrices = await Promise.all([
        buildIndexPriceWithValue(index, '2003000000'),
        buildIndexPriceWithValue(index, '28200000000', 'BTC'),
      ]);

      console.log('--- BELOW WATER ---');
      console.log('Trader1');
      await logWalletBalances(trader1.address, exchange, newIndexLowPrices);
      console.log('Insurance fund');
      await logWalletBalances(
        insuranceFund.address,
        exchange,
        newIndexLowPrices,
      );

      /*
      console.log('Trader2');
      await logWalletBalances(trader2.address, exchange, newIndexLowPrices);
      */

      /*
      await (
        await exchange.setMarketOverrides(
          insuranceFund.address,
          'ETH',
          '100000000',
          '100000000',
          '1000000',
          '14000000000',
          '2800000000',
          '282000000000',
        )
      ).wait();
      */

      await (
        await exchange
          .connect(dispatcher)
          .liquidateWalletInMaintenance(
            trader1.address,
            ['1993.11863060', '28060.88136940'].map(decimalToPips),
            newIndexLowPrices,
            newIndexLowPrices,
          )
      ).wait();

      console.log('--- LIQUIDATED ---');

      console.log('Trader1');
      await logWalletBalances(trader1.address, exchange, newIndexLowPrices);
      console.log('Insurance fund');
      await logWalletBalances(
        insuranceFund.address,
        exchange,
        newIndexLowPrices,
      );

      /*
      await (
        await exchange
          .connect(dispatcher)
          .liquidationClosureDeleverage(
            'ETH',
            trader1.address,
            decimalToPips('1993.11863060'),
            newIndexLowPrices,
          )
      ).wait();

      console.log('--- CLOSED ---');
      */

      /* await (
        await exchange.connect(dispatcher).liquidationAcquisitionDeleverage(
          LiquidationType.InMaintenance,
          'ETH',
          trader2.address,
          trader1.address,
          ['1993.11863060', '28060.88136940'].map(decimalToPips),
          decimalToPips('0.50000000'),
          decimalToPips('996.55931530'),
          //decimalToPips('1.00000000'),
          //decimalToPips('1993.11863060'),
          //[newIndexLowPrices[1]],
          newIndexLowPrices,
          newIndexLowPrices,
          newIndexLowPrices,
        )
      ).wait(); 

      await (
        await exchange
          .connect(dispatcher)
          .liquidatePositionBelowMinimum(
            'ETH',
            trader2.address,
            decimalToPips('-2003.00000000'),
            newIndexLowPrices,
            newIndexLowPrices,
          )
      ).wait();

      console.log('--- LIQUIDATED ---');

      console.log('Trader1');
      await logWalletBalances(trader1.address, exchange, newIndexLowPrices);
      await logWalletBalances(trader1.address, exchange, [
        newIndexLowPrices[1],
      ]);
      console.log('Trader2');
      await logWalletBalances(trader2.address, exchange, newIndexLowPrices);
      */

      /*
      console.log('Trader1');
      await logWalletBalances(trader1.address, exchange, [
        newIndexLowPrices[1],
      ]);

      console.log('Trader2');
      await logWalletBalances(trader2.address, exchange, [
        newIndexLowPrices[1],
      ]);
      */

      /*
      console.log('Insurance fund');
      await logWalletBalances(
        insuranceFund.address,
        exchange,
        newIndexLowPrices,
      );
      */

      /*
      const newIndexLowPrice = await buildIndexPriceWithValue(
        index,
        '999000000',
      );
      const newIndexHighPrice = await buildIndexPriceWithValue(
        index,
        new BigNumber(indexPrice.priceInAssetUnits).muln(2).toString(),
      );

      
   
     */
      /*
      console.log('Trader2');
      await logWalletBalances(trader2.address, exchange, [newIndexHighPrice]);

      console.log('Insurance fund');
      await logWalletBalances(insuranceFund.address, exchange, [
        newIndexLowPrice,
      ]);

      await (
        await exchange
          .connect(dispatcher)
          .liquidate(trader2.address, [newIndexHighPrice])
      ).wait();

      console.log('Trader2');
      await logWalletBalances(trader2.address, exchange, [newIndexHighPrice]);

      console.log('Insurance fund');
      await logWalletBalances(insuranceFund.address, exchange, [
        newIndexLowPrice,
      ]);
      */
    });
  });
});
