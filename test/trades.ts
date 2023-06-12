import { mine } from '@nomicfoundation/hardhat-network-helpers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { v1 as uuidv1 } from 'uuid';
import { ethers, network } from 'hardhat';

import {
  baseAssetSymbol,
  buildIndexPrice,
  buildIndexPriceWithValue,
  deployAndAssociateContracts,
  executeTrade,
  expect,
  fundWallets,
  quoteAssetDecimals,
  quoteAssetSymbol,
} from './helpers';
import {
  decimalToPips,
  getDelegatedKeyAuthorizationSignatureTypedData,
  getExecuteTradeArguments,
  getOrderSignatureTypedData,
  indexPriceToArgumentStruct,
  Order,
  OrderSide,
  OrderTimeInForce,
  OrderTriggerType,
  OrderType,
  Trade,
  uuidToHexString,
} from '../lib';
import type {
  Exchange_v4,
  Governance,
  IDEXIndexAndOraclePriceAdapter,
  USDC,
} from '../typechain-types';

describe('Exchange', function () {
  let buyOrder: Order;
  let buyOrderSignature: string;
  let dispatcherWallet: SignerWithAddress;
  let exchange: Exchange_v4;
  let exitFundWallet: SignerWithAddress;
  let governance: Governance;
  let indexPriceAdapter: IDEXIndexAndOraclePriceAdapter;
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
    governance = results.governance;
    indexPriceAdapter = results.indexPriceAdapter;
    usdc = results.usdc;

    await usdc.faucet(dispatcherWallet.address);

    await fundWallets([trader1Wallet, trader2Wallet], exchange, results.usdc);

    await exchange
      .connect(dispatcherWallet)
      .publishIndexPrices([
        indexPriceToArgumentStruct(
          indexPriceAdapter.address,
          await buildIndexPrice(exchange.address, indexPriceServiceWallet),
        ),
      ]);

    buyOrder = {
      nonce: uuidv1(),
      wallet: trader2Wallet.address,
      market: `${baseAssetSymbol}-USD`,
      type: OrderType.Limit,
      side: OrderSide.Buy,
      quantity: '10.00000000',
      price: '2000.00000000',
    };
    buyOrderSignature = await trader2Wallet._signTypedData(
      ...getOrderSignatureTypedData(buyOrder, exchange.address),
    );

    sellOrder = {
      nonce: uuidv1(),
      wallet: trader1Wallet.address,
      market: `${baseAssetSymbol}-USD`,
      type: OrderType.Limit,
      side: OrderSide.Sell,
      quantity: '10.00000000',
      price: '2000.00000000',
    };
    sellOrderSignature = await trader1Wallet._signTypedData(
      ...getOrderSignatureTypedData(sellOrder, exchange.address),
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
  });

  describe('executeTrade', () => {
    it('test', async function () {
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

      const aggregator = await (
        await ethers.getContractFactory('ExchangeWalletStateAggregator')
      ).deploy(exchange.address);

      console.log(
        await aggregator.loadWalletStates([
          trader1Wallet.address,
          trader2Wallet.address,
        ]),
      );
    });

    it('should work for limit orders with maker sell', async function () {
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

      expect(
        (
          await exchange.loadBalanceBySymbol(
            trader2Wallet.address,
            baseAssetSymbol,
          )
        ).toString(),
      ).to.equal(decimalToPips('10.00000000'));

      expect(
        (
          await exchange.loadBalanceStructBySymbol(
            trader1Wallet.address,
            baseAssetSymbol,
          )
        ).balance.toString(),
      ).to.equal(decimalToPips('-10.00000000'));
    });

    it('should work when increasing position sizes', async function () {
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

      await fundWallets([trader1Wallet, trader2Wallet], exchange, usdc);

      await executeTrade(
        exchange,
        dispatcherWallet,
        await buildIndexPrice(exchange.address, indexPriceServiceWallet),
        indexPriceAdapter.address,
        trader1Wallet,
        trader2Wallet,
      );

      expect(
        (
          await exchange.loadBalanceBySymbol(
            trader2Wallet.address,
            baseAssetSymbol,
          )
        ).toString(),
      ).to.equal(decimalToPips('20.00000000'));

      expect(
        (
          await exchange.loadBalanceStructBySymbol(
            trader1Wallet.address,
            baseAssetSymbol,
          )
        ).balance.toString(),
      ).to.equal(decimalToPips('-20.00000000'));
    });

    it('should work when reducing position sizes', async function () {
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

      await fundWallets([trader1Wallet, trader2Wallet], exchange, usdc);

      await executeTrade(
        exchange,
        dispatcherWallet,
        await buildIndexPrice(exchange.address, indexPriceServiceWallet),
        indexPriceAdapter.address,
        trader2Wallet,
        trader1Wallet,
        baseAssetSymbol,
        '2000.00000000',
        '5.00000000',
      );

      expect(
        (
          await exchange.loadBalanceBySymbol(
            trader2Wallet.address,
            baseAssetSymbol,
          )
        ).toString(),
      ).to.equal(decimalToPips('5.00000000'));

      expect(
        (
          await exchange.loadBalanceStructBySymbol(
            trader1Wallet.address,
            baseAssetSymbol,
          )
        ).balance.toString(),
      ).to.equal(decimalToPips('-5.00000000'));
    });

    it('should work when flipping position signs', async function () {
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

      await fundWallets([trader1Wallet, trader2Wallet], exchange, usdc);

      await executeTrade(
        exchange,
        dispatcherWallet,
        await buildIndexPrice(exchange.address, indexPriceServiceWallet),
        indexPriceAdapter.address,
        trader2Wallet,
        trader1Wallet,
        baseAssetSymbol,
        '2000.00000000',
        '15.00000000',
      );

      expect(
        (
          await exchange.loadBalanceBySymbol(
            trader2Wallet.address,
            baseAssetSymbol,
          )
        ).toString(),
      ).to.equal(decimalToPips('-5.00000000'));

      expect(
        (
          await exchange.loadBalanceStructBySymbol(
            trader1Wallet.address,
            baseAssetSymbol,
          )
        ).balance.toString(),
      ).to.equal(decimalToPips('5.00000000'));
    });

    it('should work for for order with invalidation pending', async function () {
      await exchange.setChainPropagationPeriod(100);

      await exchange
        .connect(trader2Wallet)
        .invalidateNonce(uuidToHexString(uuidv1()));

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
    });

    it('should work for limit orders with maker rebate', async function () {
      trade.makerFeeQuantity = '-10.00000000';
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
    });

    it('should work for IF buy reducing position when signed by DK', async function () {
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

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            indexPriceAdapter.address,
            await buildIndexPriceWithValue(
              exchange.address,
              indexPriceServiceWallet,
              '2150.00000000',
              baseAssetSymbol,
            ),
          ),
        ]);
      await fundWallets([insuranceFundWallet], exchange, usdc);
      await exchange.connect(dispatcherWallet).liquidateWalletInMaintenance({
        counterpartyWallet: insuranceFundWallet.address,
        liquidatingWallet: trader1Wallet.address,
        liquidationQuoteQuantities: ['21980.00000000'].map(decimalToPips),
      });

      await exchange.setDelegateKeyExpirationPeriod(1 * 60 * 60 * 1000);
      const delegatedKeyWallet = (await ethers.getSigners())[10];
      const insuranceFundDelegatedKeyAuthorizationFields = {
        nonce: uuidv1(),
        delegatedPublicKey: delegatedKeyWallet.address,
      };
      const insuranceFundDelegatedKeyAuthorization = {
        ...insuranceFundDelegatedKeyAuthorizationFields,
        signature: await insuranceFundWallet._signTypedData(
          ...getDelegatedKeyAuthorizationSignatureTypedData(
            insuranceFundDelegatedKeyAuthorizationFields,
            exchange.address,
          ),
        ),
      };
      const insuranceFundBuyOrder: Order = {
        nonce: uuidv1({ msecs: new Date().getTime() + 1000 }),
        wallet: insuranceFundWallet.address,
        market: `${baseAssetSymbol}-USD`,
        type: OrderType.Market,
        side: OrderSide.Buy,
        quantity: '10.00000000',
        price: '0.00000000',
        isReduceOnly: true,
      };
      insuranceFundBuyOrder.delegatedPublicKey = delegatedKeyWallet.address;
      const insuranceFundOrderSignature =
        await delegatedKeyWallet._signTypedData(
          ...getOrderSignatureTypedData(
            insuranceFundBuyOrder,
            exchange.address,
          ),
        );

      sellOrder = {
        nonce: uuidv1({ msecs: new Date().getTime() + 1000 }),
        wallet: trader2Wallet.address,
        market: `${baseAssetSymbol}-USD`,
        type: OrderType.Limit,
        side: OrderSide.Sell,
        quantity: '10.00000000',
        price: '2000.00000000',
      };
      sellOrderSignature = await trader2Wallet._signTypedData(
        ...getOrderSignatureTypedData(sellOrder, exchange.address),
      );

      await exchange
        .connect(dispatcherWallet)
        .executeTrade(
          ...getExecuteTradeArguments(
            insuranceFundBuyOrder,
            insuranceFundOrderSignature,
            sellOrder,
            sellOrderSignature,
            trade,
            insuranceFundDelegatedKeyAuthorization,
          ),
        );
    });

    it('should work for IF sell reducing position when signed by DK', async function () {
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

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            indexPriceAdapter.address,
            await buildIndexPriceWithValue(
              exchange.address,
              indexPriceServiceWallet,
              '1850.00000000',
              baseAssetSymbol,
            ),
          ),
        ]);

      await fundWallets([insuranceFundWallet], exchange, usdc);
      await exchange.connect(dispatcherWallet).liquidateWalletInMaintenance({
        counterpartyWallet: insuranceFundWallet.address,
        liquidatingWallet: trader2Wallet.address,
        liquidationQuoteQuantities: ['18040.00000000'].map(decimalToPips),
      });

      await exchange.setDelegateKeyExpirationPeriod(1 * 60 * 60 * 1000);
      const delegatedKeyWallet = (await ethers.getSigners())[10];
      const insuranceFundDelegatedKeyAuthorizationFields = {
        nonce: uuidv1(),
        delegatedPublicKey: delegatedKeyWallet.address,
      };
      const insuranceFundDelegatedKeyAuthorization = {
        ...insuranceFundDelegatedKeyAuthorizationFields,
        signature: await insuranceFundWallet._signTypedData(
          ...getDelegatedKeyAuthorizationSignatureTypedData(
            insuranceFundDelegatedKeyAuthorizationFields,
            exchange.address,
          ),
        ),
      };
      const insuranceFundSellOrder: Order = {
        nonce: uuidv1({ msecs: new Date().getTime() + 1000 }),
        wallet: insuranceFundWallet.address,
        market: `${baseAssetSymbol}-USD`,
        type: OrderType.Market,
        side: OrderSide.Sell,
        quantity: '10.00000000',
        price: '0.00000000',
        isReduceOnly: true,
      };
      insuranceFundSellOrder.delegatedPublicKey = delegatedKeyWallet.address;
      const insuranceFundSellOrderSignature =
        await delegatedKeyWallet._signTypedData(
          ...getOrderSignatureTypedData(
            insuranceFundSellOrder,
            exchange.address,
          ),
        );

      buyOrder = {
        nonce: uuidv1({ msecs: new Date().getTime() + 1000 }),
        wallet: trader1Wallet.address,
        market: `${baseAssetSymbol}-USD`,
        type: OrderType.Limit,
        side: OrderSide.Buy,
        quantity: '10.00000000',
        price: '2000.00000000',
      };
      buyOrderSignature = await trader1Wallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

      await exchange
        .connect(dispatcherWallet)
        .executeTrade(
          ...getExecuteTradeArguments(
            buyOrder,
            buyOrderSignature,
            insuranceFundSellOrder,
            insuranceFundSellOrderSignature,
            trade,
            undefined,
            insuranceFundDelegatedKeyAuthorization,
          ),
        );
    });

    it('should work for buy order signed by DK', async function () {
      await exchange.setDelegateKeyExpirationPeriod(1 * 60 * 60 * 1000);
      const delegatedKeyWallet = (await ethers.getSigners())[10];
      const buyDelegatedKeyAuthorizationFields = {
        nonce: uuidv1(),
        delegatedPublicKey: delegatedKeyWallet.address,
      };
      const buyDelegatedKeyAuthorization = {
        ...buyDelegatedKeyAuthorizationFields,
        signature: await trader2Wallet._signTypedData(
          ...getDelegatedKeyAuthorizationSignatureTypedData(
            buyDelegatedKeyAuthorizationFields,
            exchange.address,
          ),
        ),
      };

      buyOrder.nonce = uuidv1({ msecs: new Date().getTime() + 1000 });
      buyOrder.delegatedPublicKey = delegatedKeyWallet.address;
      buyOrderSignature = await delegatedKeyWallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

      await exchange
        .connect(dispatcherWallet)
        .executeTrade(
          ...getExecuteTradeArguments(
            buyOrder,
            buyOrderSignature,
            sellOrder,
            sellOrderSignature,
            trade,
            buyDelegatedKeyAuthorization,
          ),
        );
    });

    it('should work for limit orders with maker buy', async function () {
      trade.makerSide = OrderSide.Buy;

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
    });

    it('should work for partial fill', async function () {
      trade.baseQuantity = '5.00000000';
      trade.quoteQuantity = '10000.00000000';

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
    });

    it('should work for limit maker buy gtx order ', async function () {
      buyOrder.timeInForce = OrderTimeInForce.GTX;
      buyOrderSignature = await trader2Wallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );
      trade.makerSide = OrderSide.Buy;

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
    });

    it('should work for limit maker sell gtx order ', async function () {
      sellOrder.timeInForce = OrderTimeInForce.GTX;
      sellOrderSignature = await trader1Wallet._signTypedData(
        ...getOrderSignatureTypedData(sellOrder, exchange.address),
      );

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
    });

    it('should work for limit taker ioc order ', async function () {
      buyOrder.timeInForce = OrderTimeInForce.IOC;
      buyOrderSignature = await trader2Wallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

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
    });

    it('should work for limit taker fok order ', async function () {
      buyOrder.timeInForce = OrderTimeInForce.FOK;
      buyOrderSignature = await trader2Wallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

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
    });

    it('should revert when buy side exceeds max position size', async function () {
      buyOrder.quantity = '20.00000000';
      buyOrderSignature = await trader2Wallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

      sellOrder.quantity = '20.00000000';
      sellOrderSignature = await trader1Wallet._signTypedData(
        ...getOrderSignatureTypedData(sellOrder, exchange.address),
      );

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

      const overrides = {
        initialMarginFraction: '5000000',
        maintenanceMarginFraction: '3000000',
        incrementalInitialMarginFraction: '1000000',
        baselinePositionSize: '14000000000',
        incrementalPositionSize: '2800000000',
        maximumPositionSize: '1000000000',
        minimumPositionSize: '10000000',
      };
      await governance
        .connect(ownerWallet)
        .initiateMarketOverridesUpgrade(
          baseAssetSymbol,
          overrides,
          trader2Wallet.address,
        );
      await mine((1 * 24 * 60 * 60) / 3, { interval: 0 });
      await governance
        .connect(dispatcherWallet)
        .finalizeMarketOverridesUpgrade(
          baseAssetSymbol,
          overrides,
          trader2Wallet.address,
        );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/max position size exceeded/i);
    });

    it('should revert when sell side exceeds max position size', async function () {
      buyOrder.quantity = '20.00000000';
      buyOrderSignature = await trader2Wallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

      sellOrder.quantity = '20.00000000';
      sellOrderSignature = await trader1Wallet._signTypedData(
        ...getOrderSignatureTypedData(sellOrder, exchange.address),
      );

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

      const overrides = {
        initialMarginFraction: '5000000',
        maintenanceMarginFraction: '3000000',
        incrementalInitialMarginFraction: '1000000',
        baselinePositionSize: '14000000000',
        incrementalPositionSize: '2800000000',
        maximumPositionSize: '1000000000',
        minimumPositionSize: '10000000',
      };
      await governance
        .connect(ownerWallet)
        .initiateMarketOverridesUpgrade(
          baseAssetSymbol,
          overrides,
          trader1Wallet.address,
        );
      await mine((1 * 24 * 60 * 60) / 3, { interval: 0 });
      await governance
        .connect(dispatcherWallet)
        .finalizeMarketOverridesUpgrade(
          baseAssetSymbol,
          overrides,
          trader1Wallet.address,
        );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/max position size exceeded/i);
    });

    it('should revert for invalidated buy order DK', async function () {
      await exchange.setDelegateKeyExpirationPeriod(1 * 60 * 60 * 1000);
      const delegatedKeyWallet = (await ethers.getSigners())[10];
      const buyDelegatedKeyAuthorizationFields = {
        nonce: uuidv1(),
        delegatedPublicKey: delegatedKeyWallet.address,
      };
      const buyDelegatedKeyAuthorization = {
        ...buyDelegatedKeyAuthorizationFields,
        signature: await trader2Wallet._signTypedData(
          ...getDelegatedKeyAuthorizationSignatureTypedData(
            buyDelegatedKeyAuthorizationFields,
            exchange.address,
          ),
        ),
      };
      await exchange
        .connect(trader2Wallet)
        .invalidateNonce(
          uuidToHexString(buyDelegatedKeyAuthorizationFields.nonce),
        );

      buyOrder.nonce = uuidv1();
      buyOrder.delegatedPublicKey = delegatedKeyWallet.address;
      buyOrderSignature = await delegatedKeyWallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
              buyDelegatedKeyAuthorization,
            ),
          ),
      ).to.eventually.be.rejectedWith(/buy order delegated key invalidated/i);
    });

    it('should revert for invalidated sell order DK', async function () {
      await exchange.setDelegateKeyExpirationPeriod(1 * 60 * 60 * 1000);
      const delegatedKeyWallet = (await ethers.getSigners())[10];
      const sellDelegatedKeyAuthorizationFields = {
        nonce: uuidv1(),
        delegatedPublicKey: delegatedKeyWallet.address,
      };
      const sellDelegatedKeyAuthorization = {
        ...sellDelegatedKeyAuthorizationFields,
        signature: await trader2Wallet._signTypedData(
          ...getDelegatedKeyAuthorizationSignatureTypedData(
            sellDelegatedKeyAuthorizationFields,
            exchange.address,
          ),
        ),
      };
      await exchange
        .connect(trader1Wallet)
        .invalidateNonce(
          uuidToHexString(sellDelegatedKeyAuthorizationFields.nonce),
        );

      sellOrder.nonce = uuidv1();
      sellOrder.delegatedPublicKey = delegatedKeyWallet.address;
      sellOrderSignature = await delegatedKeyWallet._signTypedData(
        ...getOrderSignatureTypedData(sellOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
              undefined,
              sellDelegatedKeyAuthorization,
            ),
          ),
      ).to.eventually.be.rejectedWith(/sell order delegated key invalidated/i);
    });

    it('should revert for expired buy order DK', async function () {
      await exchange.setDelegateKeyExpirationPeriod(0);
      const delegatedKeyWallet = (await ethers.getSigners())[10];
      const buyDelegatedKeyAuthorizationFields = {
        nonce: uuidv1(),
        delegatedPublicKey: delegatedKeyWallet.address,
      };
      const buyDelegatedKeyAuthorization = {
        ...buyDelegatedKeyAuthorizationFields,
        signature: await trader2Wallet._signTypedData(
          ...getDelegatedKeyAuthorizationSignatureTypedData(
            buyDelegatedKeyAuthorizationFields,
            exchange.address,
          ),
        ),
      };

      buyOrder.nonce = uuidv1();
      buyOrder.delegatedPublicKey = delegatedKeyWallet.address;
      buyOrderSignature = await delegatedKeyWallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
              buyDelegatedKeyAuthorization,
            ),
          ),
      ).to.eventually.be.rejectedWith(/buy order delegated key expired/i);
    });

    it('should revert for expired sell order DK', async function () {
      await exchange.setDelegateKeyExpirationPeriod(0);
      const delegatedKeyWallet = (await ethers.getSigners())[10];
      const sellDelegatedKeyAuthorizationFields = {
        nonce: uuidv1(),
        delegatedPublicKey: delegatedKeyWallet.address,
      };
      const sellDelegatedKeyAuthorization = {
        ...sellDelegatedKeyAuthorizationFields,
        signature: await trader1Wallet._signTypedData(
          ...getDelegatedKeyAuthorizationSignatureTypedData(
            sellDelegatedKeyAuthorizationFields,
            exchange.address,
          ),
        ),
      };

      sellOrder.nonce = uuidv1();
      sellOrder.delegatedPublicKey = delegatedKeyWallet.address;
      sellOrderSignature = await delegatedKeyWallet._signTypedData(
        ...getOrderSignatureTypedData(sellOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
              undefined,
              sellDelegatedKeyAuthorization,
            ),
          ),
      ).to.eventually.be.rejectedWith(/sell order delegated key expired/i);
    });

    it('should revert when buy order was placed before DK', async function () {
      await exchange.setDelegateKeyExpirationPeriod(0);
      const delegatedKeyWallet = (await ethers.getSigners())[10];
      const buyDelegatedKeyAuthorizationFields = {
        nonce: uuidv1(),
        delegatedPublicKey: delegatedKeyWallet.address,
      };
      const buyDelegatedKeyAuthorization = {
        ...buyDelegatedKeyAuthorizationFields,
        signature: await trader2Wallet._signTypedData(
          ...getDelegatedKeyAuthorizationSignatureTypedData(
            buyDelegatedKeyAuthorizationFields,
            exchange.address,
          ),
        ),
      };

      buyOrder.delegatedPublicKey = delegatedKeyWallet.address;
      buyOrderSignature = await delegatedKeyWallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
              buyDelegatedKeyAuthorization,
            ),
          ),
      ).to.eventually.be.rejectedWith(/buy order predates delegated key/i);
    });

    it('should revert when sell order was placed before DK', async function () {
      await exchange.setDelegateKeyExpirationPeriod(0);
      const delegatedKeyWallet = (await ethers.getSigners())[10];
      const sellDelegatedKeyAuthorizationFields = {
        nonce: uuidv1(),
        delegatedPublicKey: delegatedKeyWallet.address,
      };
      const sellDelegatedKeyAuthorization = {
        ...sellDelegatedKeyAuthorizationFields,
        signature: await trader2Wallet._signTypedData(
          ...getDelegatedKeyAuthorizationSignatureTypedData(
            sellDelegatedKeyAuthorizationFields,
            exchange.address,
          ),
        ),
      };

      sellOrder.delegatedPublicKey = delegatedKeyWallet.address;
      sellOrderSignature = await delegatedKeyWallet._signTypedData(
        ...getOrderSignatureTypedData(sellOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
              undefined,
              sellDelegatedKeyAuthorization,
            ),
          ),
      ).to.eventually.be.rejectedWith(/sell order predates delegated key/i);
    });

    it('should revert when EF has open positions', async function () {
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

      // Deposit additional quote to allow for EF exit withdrawal
      const depositQuantity = ethers.utils.parseUnits(
        '100000.0',
        quoteAssetDecimals,
      );
      await usdc
        .connect(ownerWallet)
        .approve(exchange.address, depositQuantity);
      await (
        await exchange
          .connect(ownerWallet)
          .deposit(depositQuantity, ethers.constants.AddressZero)
      ).wait();

      await exchange.connect(trader1Wallet).exitWallet();
      await exchange.withdrawExit(trader1Wallet.address);

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/exit fund has open positions/i);
    });

    it('should revert for invalid buy wallet signature', async function () {
      buyOrder.quantity = '10.00000001';

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(
        /invalid wallet signature for buy order/i,
      );
    });

    it('should revert for invalid sell wallet signature', async function () {
      sellOrder.quantity = '10.00000001';

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(
        /invalid wallet signature for sell order/i,
      );
    });

    it('should revert for self-trade', async function () {
      buyOrder.wallet = trader1Wallet.address;
      buyOrderSignature = await trader2Wallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/self-trading not allowed/i);
    });

    it('should revert when limit price exceeded', async function () {
      trade.quoteQuantity = '15000.00000000';

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/order limit price exceeded/i);
    });

    it('should revert for reduce-only sell that open position', async function () {
      buyOrder.isReduceOnly = true;
      buyOrderSignature = await trader2Wallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/position must be non-zero/i);
    });

    it('should revert for reduce-only sell that increases position', async function () {
      await executeTrade(
        exchange,
        dispatcherWallet,
        await buildIndexPrice(exchange.address, indexPriceServiceWallet),
        indexPriceAdapter.address,
        trader1Wallet,
        trader2Wallet,
      );

      buyOrder.isReduceOnly = true;
      buyOrderSignature = await trader2Wallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/position must move toward zero/i);
    });

    it('should revert for same assets', async function () {
      trade.baseAssetSymbol = quoteAssetSymbol;
      buyOrder.market = 'USD-USD';
      buyOrderSignature = await trader2Wallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/no active market found/i);
    });

    it('should revert for invalid market', async function () {
      buyOrder.market = 'XYZ-USD';
      buyOrderSignature = await trader2Wallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/no active market found/i);
    });

    it('should revert for invalid base quantity', async function () {
      trade.baseQuantity = '0';

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(
        /base quantity must be greater than zero/i,
      );
    });

    it('should revert for invalid quote quantity', async function () {
      trade.quoteQuantity = '0';

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(
        /quote quantity must be greater than zero/i,
      );
    });

    it('should revert for invalid quote quantity', async function () {
      buyOrder.wallet = exitFundWallet.address;
      buyOrderSignature = await exitFundWallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/EF cannot trade/i);
    });

    it('should revert for limit order with missing price', async function () {
      buyOrder.price = '0';
      buyOrderSignature = await trader2Wallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/invalid limit price/i);
    });

    it('should revert for market order with price', async function () {
      buyOrder.type = OrderType.Market;
      buyOrderSignature = await trader2Wallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/invalid limit price/i);
    });

    it('should revert for gtx order not for limit maker', async function () {
      buyOrder.type = OrderType.Market;
      buyOrder.price = '0.00000000';
      buyOrder.timeInForce = OrderTimeInForce.GTX;
      buyOrderSignature = await trader2Wallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/gtx order must be limit maker/i);
    });

    it('should revert for excessive maker rebate', async function () {
      trade.makerFeeQuantity = '-10.00000000';
      trade.takerFeeQuantity = '5.00000000';

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/excessive maker rebate/i);
    });

    it('should revert for excessive maker fee', async function () {
      trade.makerFeeQuantity = '10000.00000000';

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/excessive maker fee/i);
    });

    it('should revert for excessive taker fee', async function () {
      trade.takerFeeQuantity = '10000.00000000';

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/excessive taker fee/i);
    });

    it('should revert for IF order not signed by DK', async function () {
      buyOrder.wallet = insuranceFundWallet.address;
      buyOrderSignature = await insuranceFundWallet._signTypedData(
        ...getOrderSignatureTypedData(buyOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(
        /IF order must be reduce only and signed by DK/i,
      );
    });

    it('should revert for invalidated buy nonce', async function () {
      await exchange
        .connect(trader2Wallet)
        .invalidateNonce(uuidToHexString(uuidv1()));

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/buy order nonce timestamp invalidated/i);

      await exchange.setChainPropagationPeriod(100);
      await exchange
        .connect(trader2Wallet)
        .invalidateNonce(uuidToHexString(uuidv1()));

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/buy order nonce timestamp invalidated/i);
    });

    it('should revert for invalidated sell nonce', async function () {
      await exchange
        .connect(trader1Wallet)
        .invalidateNonce(uuidToHexString(uuidv1()));

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(
        /sell order nonce timestamp invalidated/i,
      );

      await exchange.setChainPropagationPeriod(100);
      await exchange
        .connect(trader1Wallet)
        .invalidateNonce(uuidToHexString(uuidv1()));

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(
        /sell order nonce timestamp invalidated/i,
      );
    });

    it('should revert for exited buy wallet', async function () {
      await exchange.connect(trader2Wallet).exitWallet();

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/buy wallet exit finalized/i);
    });

    it('should revert for exited sell wallet', async function () {
      await exchange.connect(trader1Wallet).exitWallet();

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/sell wallet exit finalized/i);
    });

    it('should revert for double fill', async function () {
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

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/order double filled/i);
    });

    it('should revert for overfill', async function () {
      trade.baseQuantity = '20.00000000';
      trade.quoteQuantity = '40000.00000000';

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/order overfilled/i);
    });

    it('should revert for non-taker ioc order', async function () {
      sellOrder.timeInForce = OrderTimeInForce.IOC;
      sellOrderSignature = await trader1Wallet._signTypedData(
        ...getOrderSignatureTypedData(sellOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/ioc order must be taker/i);
    });

    it('should revert for non-taker fok order', async function () {
      sellOrder.timeInForce = OrderTimeInForce.FOK;
      sellOrderSignature = await trader1Wallet._signTypedData(
        ...getOrderSignatureTypedData(sellOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/fok order must be taker/i);
    });

    it('should revert for missing trigger price for stop loss limit sell', async function () {
      sellOrder.type = OrderType.StopLossLimit;
      sellOrderSignature = await trader1Wallet._signTypedData(
        ...getOrderSignatureTypedData(sellOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/missing trigger price/i);
    });

    it('should revert for missing trigger price for stop loss market sell', async function () {
      sellOrder.type = OrderType.StopLossMarket;
      sellOrder.price = '0.00000000';
      sellOrderSignature = await trader1Wallet._signTypedData(
        ...getOrderSignatureTypedData(sellOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/missing trigger price/i);
    });

    it('should revert for missing trigger price for take profit limit sell', async function () {
      sellOrder.type = OrderType.TakeProfitLimit;
      sellOrderSignature = await trader1Wallet._signTypedData(
        ...getOrderSignatureTypedData(sellOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/missing trigger price/i);
    });

    it('should revert for missing trigger price for take profit market sell', async function () {
      sellOrder.type = OrderType.TakeProfitMarket;
      sellOrder.price = '0.00000000';
      sellOrderSignature = await trader1Wallet._signTypedData(
        ...getOrderSignatureTypedData(sellOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/missing trigger price/i);
    });

    it('should revert for invalid trigger price', async function () {
      sellOrder.triggerPrice = '2100.00000000';
      sellOrderSignature = await trader1Wallet._signTypedData(
        ...getOrderSignatureTypedData(sellOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/invalid trigger price/i);
    });

    it('should revert for missing callback rate', async function () {
      sellOrder.type = OrderType.TrailingStop;
      sellOrder.price = '0.00000000';
      sellOrderSignature = await trader1Wallet._signTypedData(
        ...getOrderSignatureTypedData(sellOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/invalid callback rate/i);
    });

    it('should revert for invalid callback rate', async function () {
      sellOrder.callbackRate = '0.50000000';
      sellOrderSignature = await trader1Wallet._signTypedData(
        ...getOrderSignatureTypedData(sellOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/invalid callback rate/i);
    });

    it('should revert for invalid trigger type', async function () {
      sellOrder.type = OrderType.StopLossLimit;
      sellOrder.triggerPrice = '2100.00000000';
      sellOrderSignature = await trader1Wallet._signTypedData(
        ...getOrderSignatureTypedData(sellOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/invalid trigger type/i);
    });

    it('should revert for invalid trigger type', async function () {
      sellOrder.triggerType = OrderTriggerType.Index;
      sellOrderSignature = await trader1Wallet._signTypedData(
        ...getOrderSignatureTypedData(sellOrder, exchange.address),
      );

      await expect(
        exchange
          .connect(dispatcherWallet)
          .executeTrade(
            ...getExecuteTradeArguments(
              buyOrder,
              buyOrderSignature,
              sellOrder,
              sellOrderSignature,
              trade,
            ),
          ),
      ).to.eventually.be.rejectedWith(/invalid trigger type/i);
    });
  });
});
