import { expect } from 'chai';
import { ethers } from 'hardhat';
import { v1 as uuidv1 } from 'uuid';

import {
  decimalToPips,
  getDelegatedKeyAuthorizationHash,
  getExecuteOrderBookTradeArguments,
  getOrderHash,
  getWithdrawalHash,
  getWithdrawArguments,
  Order,
  OrderSide,
  OrderType,
  signatureHashVersion,
  Trade,
} from '../lib';

import {
  buildFundingRates,
  buildOraclePrice,
  buildOraclePrices,
  collateralAssetDecimals,
  deployAndAssociateContracts,
  fundWallets,
  logWalletBalances,
} from './helpers';

describe('Exchange', function () {
  it('deposit and withdraw should work', async function () {
    const [owner, dispatcher, trader, oracle] = await ethers.getSigners();
    const { exchange, usdc } = await deployAndAssociateContracts(
      owner,
      dispatcher,
      oracle,
    );

    const depositQuantity = ethers.utils.parseUnits(
      '5.0',
      collateralAssetDecimals,
    );
    await usdc.transfer(trader.address, depositQuantity);
    await usdc.connect(trader).approve(exchange.address, depositQuantity);
    await (await exchange.connect(trader).deposit(depositQuantity)).wait();

    const depositedEvents = await exchange.queryFilter(
      exchange.filters.Deposited(),
    );
    /*
    expect(depositedEvents.length).to.equal(1);
    expect(depositedEvents[0].args?.quantityInPips).to.equal(
      decimalToPips('1.00000000'),
    );
    */

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
            await buildOraclePrice(oracle),
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
            await buildOraclePrice(oracle),
          ]),
        )
    ).wait();

    /*
    const withdrawnEvents = await exchange.queryFilter(
      exchange.filters.Withdrawn(),
    );
    expect(withdrawnEvents.length).to.equal(1);
    expect(withdrawnEvents.length).to.equal(1);
    expect(withdrawnEvents[0].args?.quantityInPips).to.equal(
      decimalToPips('1.00000000'),
    );
    */
  });

  it('publishFundingMutipliers should work', async function () {
    const [owner, dispatcher, oracle] = await ethers.getSigners();
    const { exchange } = await deployAndAssociateContracts(
      owner,
      dispatcher,
      oracle,
    );

    await (
      await exchange
        .connect(dispatcher)
        .publishFundingMutipliers(
          await buildOraclePrices(oracle, 5),
          buildFundingRates(5),
        )
    ).wait();
  });

  it.only('executeOrderBookTrade should work', async function () {
    const [
      owner,
      dispatcher,
      oracle,
      trader1,
      trader2,
      trader1Delegate,
      feeWallet,
    ] = await ethers.getSigners();
    const { exchange, usdc } = await deployAndAssociateContracts(
      owner,
      dispatcher,
      oracle,
      feeWallet,
    );

    await fundWallets([trader1, trader2], exchange, usdc);

    await (await exchange.setDelegateKeyExpirationPeriod(10000000)).wait();

    const trader1DelegatedKeyAuthorization = {
      delegatedPublicKey: trader1Delegate.address,
      nonce: uuidv1({ msecs: new Date().getTime() - 1000 }),
    };
    const trader1DelegatedKeyAuthorizationSignature = await trader1.signMessage(
      ethers.utils.arrayify(
        getDelegatedKeyAuthorizationHash(
          trader1.address,
          trader1DelegatedKeyAuthorization,
        ),
      ),
    );
    const sellDelegatedKeyAuthorization = {
      ...trader1DelegatedKeyAuthorization,
      signature: trader1DelegatedKeyAuthorizationSignature,
    };

    const sellOrder: Order = {
      signatureHashVersion,
      nonce: uuidv1({ msecs: new Date().getTime() - 12 * 60 * 60 * 1000 }),
      wallet: trader1.address,
      market: 'ETH-USDC',
      type: OrderType.Limit,
      side: OrderSide.Sell,
      quantity: '1.00000000',
      isQuantityInQuote: false,
      price: '2000.00000000',
    };
    const sellOrderSignature = await trader1Delegate.signMessage(
      ethers.utils.arrayify(
        getOrderHash(sellOrder, sellDelegatedKeyAuthorization),
      ),
    );

    const buyOrder: Order = {
      signatureHashVersion,
      nonce: uuidv1({ msecs: new Date().getTime() - 12 * 60 * 60 * 1000 }),
      wallet: trader2.address,
      market: 'ETH-USDC',
      type: OrderType.Limit,
      side: OrderSide.Buy,
      quantity: '1.00000000',
      isQuantityInQuote: false,
      price: '2000.00000000',
    };
    const buyOrderSignature = await trader2.signMessage(
      ethers.utils.arrayify(getOrderHash(buyOrder)),
    );

    const trade: Trade = {
      baseAssetSymbol: 'ETH',
      quoteAssetSymbol: 'USD',
      baseQuantity: '1.00000000',
      quoteQuantity: '2000.00000000',
      makerFeeQuantity: '2.00000000',
      takerFeeQuantity: '4.00000000',
      price: '1.00000000',
      makerSide: OrderSide.Sell,
    };

    const oraclePrice = await buildOraclePrice(oracle);

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
            [oraclePrice],
            undefined,
            sellDelegatedKeyAuthorization,
          ),
        )
    ).wait();
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
            await buildOraclePrice(oracle),
          ]),
        )
    ).wait();*/

    await (
      await exchange
        .connect(dispatcher)
        .publishFundingMutipliers(
          await buildOraclePrices(oracle, 10),
          buildFundingRates(10),
        )
    ).wait();
    /*
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
            await buildOraclePrice(oracle),
          ]),
        )
    ).wait();*/

    console.log('Trader1');
    await logWalletBalances(trader1.address, exchange, [oraclePrice]);

    console.log('Trader2');
    await logWalletBalances(trader2.address, exchange, [oraclePrice]);

    const sellOrder2: Order = {
      signatureHashVersion,
      nonce: uuidv1(),
      wallet: trader1.address,
      market: 'ETH-USDC',
      type: OrderType.Limit,
      side: OrderSide.Sell,
      quantity: '1.00000000',
      isQuantityInQuote: false,
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
      isQuantityInQuote: false,
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
            [oraclePrice],
            undefined,
            sellDelegatedKeyAuthorization,
          ),
        )
    ).wait();

    console.log('Trader1');
    await logWalletBalances(trader1.address, exchange, [oraclePrice]);

    console.log('Trader2');
    await logWalletBalances(trader2.address, exchange, [oraclePrice]);
  });
});
