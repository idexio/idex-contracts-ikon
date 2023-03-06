import { ethers } from 'hardhat';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { v1 as uuidv1 } from 'uuid';

import type { Exchange_v4, USDC } from '../typechain-types';
import {
  getDelegatedKeyAuthorizationMessage,
  getExecuteTradeArguments,
  getOrderHash,
  indexPriceToArgumentStruct,
  Order,
  OrderSide,
  OrderTimeInForce,
  OrderTriggerType,
  OrderType,
  signatureHashVersion,
  Trade,
  uuidToHexString,
} from '../lib';
import {
  baseAssetSymbol,
  buildIndexPrice,
  deployAndAssociateContracts,
  executeTrade,
  expect,
  fundWallets,
  quoteAssetDecimals,
  quoteAssetSymbol,
} from './helpers';

describe('Exchange', function () {
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

    await fundWallets([trader1Wallet, trader2Wallet], exchange, results.usdc);

    await exchange
      .connect(dispatcherWallet)
      .publishIndexPrices([
        indexPriceToArgumentStruct(
          await buildIndexPrice(indexPriceServiceWallet),
        ),
      ]);

    sellOrder = {
      signatureHashVersion,
      nonce: uuidv1({ msecs: new Date().getTime() - 100 * 60 * 60 * 1000 }),
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

    buyOrder = {
      signatureHashVersion,
      nonce: uuidv1({ msecs: new Date().getTime() - 100 * 60 * 60 * 1000 }),
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
    });

    it('should work for buy order signed by DK', async function () {
      await exchange.setDelegateKeyExpirationPeriod(1 * 60 * 60 * 1000);
      const delegatedKeyWallet = (await ethers.getSigners())[10];
      const buyDelegatedKeyAuthorizationFields = {
        signatureHashVersion,
        nonce: uuidv1(),
        delegatedPublicKey: delegatedKeyWallet.address,
      };
      const buyDelegatedKeyAuthorization = {
        ...buyDelegatedKeyAuthorizationFields,
        signature: await trader2Wallet.signMessage(
          getDelegatedKeyAuthorizationMessage(
            buyDelegatedKeyAuthorizationFields,
          ),
        ),
      };

      buyOrder.nonce = uuidv1();
      buyOrder.delegatedPublicKey = delegatedKeyWallet.address;
      buyOrderSignature = await delegatedKeyWallet.signMessage(
        ethers.utils.arrayify(getOrderHash(buyOrder)),
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

    it('should revert for self-trade', async function () {
      buyOrder.wallet = trader1Wallet.address;
      buyOrderSignature = await trader2Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(buyOrder)),
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

    it('should revert for reduce-only sell that open position', async function () {
      buyOrder.isReduceOnly = true;
      buyOrderSignature = await trader2Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(buyOrder)),
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
        await buildIndexPrice(indexPriceServiceWallet),
        trader1Wallet,
        trader2Wallet,
      );

      buyOrder.isReduceOnly = true;
      buyOrderSignature = await trader2Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(buyOrder)),
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
      buyOrderSignature = await trader2Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(buyOrder)),
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
      ).to.eventually.be.rejectedWith(/trade assets must be different/i);
    });

    it('should revert for invalid market', async function () {
      buyOrder.market = 'XYZ-USD';
      buyOrderSignature = await trader2Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(buyOrder)),
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
      buyOrderSignature = await exitFundWallet.signMessage(
        ethers.utils.arrayify(getOrderHash(buyOrder)),
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
      buyOrderSignature = await trader2Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(buyOrder)),
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
      buyOrderSignature = await trader2Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(buyOrder)),
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
      buyOrderSignature = await trader2Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(buyOrder)),
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
      buyOrderSignature = await insuranceFundWallet.signMessage(
        ethers.utils.arrayify(getOrderHash(buyOrder)),
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
      sellOrderSignature = await trader1Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(sellOrder)),
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
      sellOrderSignature = await trader1Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(sellOrder)),
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

    it('should revert for missing trigger price', async function () {
      sellOrder.type = OrderType.StopLossLimit;
      sellOrderSignature = await trader1Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(sellOrder)),
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
      sellOrderSignature = await trader1Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(sellOrder)),
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
      sellOrderSignature = await trader1Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(sellOrder)),
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
      sellOrderSignature = await trader1Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(sellOrder)),
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
      sellOrderSignature = await trader1Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(sellOrder)),
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
      sellOrderSignature = await trader1Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(sellOrder)),
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

    it('should revert for invalid signature hash version', async function () {
      sellOrder.signatureHashVersion = 177;
      sellOrderSignature = await trader1Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(sellOrder)),
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
      ).to.eventually.be.rejectedWith(/signature hash version invalid/i);
    });
  });
});
