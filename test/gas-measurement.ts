import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { v1 as uuidv1 } from 'uuid';
import { ethers, network } from 'hardhat';
import { mine, time } from '@nomicfoundation/hardhat-network-helpers';

import {
  baseAssetSymbol,
  buildIndexPrice,
  buildIndexPriceWithTimestamp,
  buildIndexPriceWithValue,
  deployAndAssociateContracts,
  fundWallets,
  getLatestBlockTimestampInSeconds,
} from './helpers';
import {
  decimalToPips,
  fundingPeriodLengthInMs,
  getExecuteTradeArguments,
  getOrderHash,
  getTransferArguments,
  getTransferSignatureTypedData,
  getWithdrawArguments,
  getWithdrawalSignatureTypedData,
  indexPriceToArgumentStruct,
  Order,
  OrderSide,
  OrderType,
  signatureHashVersion,
  Trade,
} from '../lib';
import type { Exchange_v4, Governance, USDC } from '../typechain-types';
import { MarketStruct } from '../typechain-types/contracts/Exchange.sol/Exchange_v4';

describe.skip('Gas measurement', function () {
  let buyOrder: Order;
  let buyOrderSignature: string;
  let dispatcherWallet: SignerWithAddress;
  let exchange: Exchange_v4;
  let exitFundWallet: SignerWithAddress;
  let governance: Governance;
  let indexPriceServiceWallet: SignerWithAddress;
  let insuranceFundWallet: SignerWithAddress;
  let marketStruct: MarketStruct;
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
    usdc = results.usdc;

    marketStruct = {
      exists: true,
      isActive: false,
      baseAssetSymbol,
      chainlinkPriceFeedAddress: results.chainlinkAggregator.address,
      indexPriceAtDeactivation: 0,
      lastIndexPrice: 0,
      lastIndexPriceTimestampInMs: 0,
      overridableFields: {
        initialMarginFraction: '5000000',
        maintenanceMarginFraction: '3000000',
        incrementalInitialMarginFraction: '1000000',
        baselinePositionSize: '14000000000',
        incrementalPositionSize: '2800000000',
        maximumPositionSize: '282000000000',
        minimumPositionSize: '10000000',
      },
    };

    await usdc.faucet(dispatcherWallet.address);

    await fundWallets(
      [trader1Wallet, trader2Wallet],
      exchange,
      results.usdc,
      '3000.00000000',
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

  describe('deleverage in maintenance', function () {
    it('for a single market', async function () {
      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPriceWithValue(
              indexPriceServiceWallet,
              '2250.00000000',
              baseAssetSymbol,
            ),
          ),
        ]);

      const result = await exchange
        .connect(dispatcherWallet)
        .deleverageInMaintenanceAcquisition({
          baseAssetSymbol,
          counterpartyWallet: trader2Wallet.address,
          liquidatingWallet: trader1Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '22980.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('22980.00000000'),
        });
      console.log((await result.wait()).gasUsed.toString());
    });

    it('for 5 markets', async function () {
      await fundWallets(
        [trader1Wallet, trader2Wallet],
        exchange,
        usdc,
        '7000.00000000',
      );

      const baseAssetSymbols = ['XYZ1', 'XYZ2', 'XYZ3', 'XYZ4'];
      await Promise.all(
        baseAssetSymbols.map((symbol) =>
          addMarket(symbol, dispatcherWallet, exchange, marketStruct),
        ),
      );

      for (const symbol of baseAssetSymbols) {
        buyOrder.nonce = uuidv1();
        buyOrder.market = `${symbol}-USD`;
        buyOrderSignature = await trader2Wallet.signMessage(
          ethers.utils.arrayify(getOrderHash(buyOrder)),
        );

        sellOrder.nonce = uuidv1();
        sellOrder.market = `${symbol}-USD`;
        sellOrderSignature = await trader1Wallet.signMessage(
          ethers.utils.arrayify(getOrderHash(sellOrder)),
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
      }

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices(
          await Promise.all(
            [...baseAssetSymbols, baseAssetSymbol].map(async (symbol) =>
              indexPriceToArgumentStruct(
                await buildIndexPriceWithValue(
                  indexPriceServiceWallet,
                  '2150.00000000',
                  symbol,
                ),
              ),
            ),
          ),
        );

      const result = await exchange
        .connect(dispatcherWallet)
        .deleverageInMaintenanceAcquisition({
          baseAssetSymbol,
          counterpartyWallet: trader2Wallet.address,
          liquidatingWallet: trader1Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '21980.00000000',
            '21980.00000000',
            '21980.00000000',
            '21980.00000000',
            '21980.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        });
      console.log((await result.wait()).gasUsed.toString());
    });
  });

  describe('Liquidate below minimum', function () {
    beforeEach(async () => {
      const overrides = {
        initialMarginFraction: '5000000',
        maintenanceMarginFraction: '3000000',
        incrementalInitialMarginFraction: '1000000',
        baselinePositionSize: '14000000000',
        incrementalPositionSize: '2800000000',
        maximumPositionSize: '282000000000',
        minimumPositionSize: '10000000000',
      };
      await governance
        .connect(ownerWallet)
        .initiateMarketOverridesUpgrade(
          baseAssetSymbol,
          overrides,
          ethers.constants.AddressZero,
        );
      await mine((1 * 24 * 60 * 60) / 3, { interval: 0 });
      await governance
        .connect(dispatcherWallet)
        .finalizeMarketOverridesUpgrade(
          baseAssetSymbol,
          overrides,
          ethers.constants.AddressZero,
        );
    });

    it('for a single market', async function () {
      await fundWallets([insuranceFundWallet], exchange, usdc);

      await exchange.connect(dispatcherWallet).liquidatePositionBelowMinimum({
        baseAssetSymbol,
        liquidatingWallet: trader1Wallet.address,
        liquidationQuoteQuantity: decimalToPips('20000.00000000'),
      });

      const result = await exchange
        .connect(dispatcherWallet)
        .liquidatePositionBelowMinimum({
          baseAssetSymbol,
          liquidatingWallet: trader2Wallet.address,
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        });
      console.log((await result.wait()).gasUsed.toString());
    });
  });

  describe('Liquidate in maintenance', function () {
    it('for a single market', async function () {
      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPriceWithValue(
              indexPriceServiceWallet,
              '2150.00000000',
              baseAssetSymbol,
            ),
          ),
        ]);
      await fundWallets([insuranceFundWallet], exchange, usdc);

      const result = await exchange
        .connect(dispatcherWallet)
        .liquidateWalletInMaintenance({
          counterpartyWallet: insuranceFundWallet.address,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantities: ['21980.00000000'].map(decimalToPips),
        });
      console.log((await result.wait()).gasUsed.toString());
    });

    it('for 5 markets', async () => {
      await fundWallets(
        [trader1Wallet, trader2Wallet],
        exchange,
        usdc,
        '8500.00000000',
      );

      await fundWallets(
        [insuranceFundWallet],
        exchange,
        usdc,
        '10000.00000000',
      );

      const baseAssetSymbols = ['XYZ1', 'XYZ2', 'XYZ3', 'XYZ4'];
      await Promise.all(
        baseAssetSymbols.map((symbol) =>
          addMarket(symbol, dispatcherWallet, exchange, marketStruct),
        ),
      );

      for (const symbol of baseAssetSymbols) {
        buyOrder.nonce = uuidv1();
        buyOrder.market = `${symbol}-USD`;
        buyOrderSignature = await trader2Wallet.signMessage(
          ethers.utils.arrayify(getOrderHash(buyOrder)),
        );

        sellOrder.nonce = uuidv1();
        sellOrder.market = `${symbol}-USD`;
        sellOrderSignature = await trader1Wallet.signMessage(
          ethers.utils.arrayify(getOrderHash(sellOrder)),
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
      }

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices(
          await Promise.all(
            [...baseAssetSymbols, baseAssetSymbol].map(async (symbol) =>
              indexPriceToArgumentStruct(
                await buildIndexPriceWithValue(
                  indexPriceServiceWallet,
                  '2150.00000000',
                  symbol,
                ),
              ),
            ),
          ),
        );

      const result = await exchange
        .connect(dispatcherWallet)
        .liquidateWalletInMaintenance({
          counterpartyWallet: insuranceFundWallet.address,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantities: [
            '22080.00000000',
            '22080.00000000',
            '22080.00000000',
            '22080.00000000',
            '22080.00000000',
          ].map(decimalToPips),
        });
      console.log((await result.wait()).gasUsed.toString());
    });
  });

  describe('Withdraw', function () {
    it('investigation 2', async function () {
      const baseAssetSymbols: string[] = ['XYZ1', 'XYZ2'];
      await Promise.all(
        baseAssetSymbols.map((symbol) =>
          addMarket(symbol, dispatcherWallet, exchange, marketStruct),
        ),
      );

      for (const symbol of baseAssetSymbols) {
        buyOrder.nonce = uuidv1();
        buyOrder.market = `${symbol}-USD`;
        buyOrderSignature = await trader2Wallet.signMessage(
          ethers.utils.arrayify(getOrderHash(buyOrder)),
        );

        sellOrder.nonce = uuidv1();
        sellOrder.market = `${symbol}-USD`;
        sellOrderSignature = await trader1Wallet.signMessage(
          ethers.utils.arrayify(getOrderHash(sellOrder)),
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
      }

      const withdrawal = {
        signatureHashVersion,
        nonce: uuidv1(),
        wallet: trader1Wallet.address,
        quantity: '1.00000000',
        bridgeAdapter: ethers.constants.AddressZero,
        bridgeAdapterPayload: '0x',
      };
      let signature = await trader1Wallet._signTypedData(
        ...getWithdrawalSignatureTypedData(withdrawal, exchange.address),
      );

      await exchange
        .connect(dispatcherWallet)
        .withdraw(...getWithdrawArguments(withdrawal, '0.00000000', signature));

      withdrawal.nonce = uuidv1();
      signature = await trader1Wallet._signTypedData(
        ...getWithdrawalSignatureTypedData(withdrawal, exchange.address),
      );

      const result = await exchange
        .connect(dispatcherWallet)
        .withdraw(...getWithdrawArguments(withdrawal, '0.00000000', signature));
      console.log((await result.wait()).gasUsed.toString());
    });

    it('investigation 1', async function () {
      const baseAssetSymbols: string[] = ['XYZ1'];
      await Promise.all(
        baseAssetSymbols.map((symbol) =>
          addMarket(symbol, dispatcherWallet, exchange, marketStruct),
        ),
      );

      for (const symbol of baseAssetSymbols) {
        buyOrder.nonce = uuidv1();
        buyOrder.market = `${symbol}-USD`;
        buyOrderSignature = await trader2Wallet.signMessage(
          ethers.utils.arrayify(getOrderHash(buyOrder)),
        );

        sellOrder.nonce = uuidv1();
        sellOrder.market = `${symbol}-USD`;
        sellOrderSignature = await trader1Wallet.signMessage(
          ethers.utils.arrayify(getOrderHash(sellOrder)),
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
      }

      const withdrawal = {
        signatureHashVersion,
        nonce: uuidv1(),
        wallet: trader1Wallet.address,
        quantity: '1.00000000',
        bridgeAdapter: ethers.constants.AddressZero,
        bridgeAdapterPayload: '0x',
      };
      let signature = await trader1Wallet._signTypedData(
        ...getWithdrawalSignatureTypedData(withdrawal, exchange.address),
      );

      await exchange
        .connect(dispatcherWallet)
        .withdraw(...getWithdrawArguments(withdrawal, '0.00000000', signature));

      withdrawal.nonce = uuidv1();
      signature = await trader1Wallet._signTypedData(
        ...getWithdrawalSignatureTypedData(withdrawal, exchange.address),
      );

      const result = await exchange
        .connect(dispatcherWallet)
        .withdraw(...getWithdrawArguments(withdrawal, '0.00000000', signature));
      console.log((await result.wait()).gasUsed.toString());
    });

    it('with no outstanding funding payments', async function () {
      const withdrawal = {
        signatureHashVersion,
        nonce: uuidv1(),
        wallet: trader1Wallet.address,
        quantity: '1.00000000',
        bridgeAdapter: ethers.constants.AddressZero,
        bridgeAdapterPayload: '0x',
      };
      let signature = await trader1Wallet._signTypedData(
        ...getWithdrawalSignatureTypedData(withdrawal, exchange.address),
      );

      await exchange
        .connect(dispatcherWallet)
        .withdraw(...getWithdrawArguments(withdrawal, '0.00000000', signature));

      withdrawal.nonce = uuidv1();
      signature = await trader1Wallet._signTypedData(
        ...getWithdrawalSignatureTypedData(withdrawal, exchange.address),
      );

      const result = await exchange
        .connect(dispatcherWallet)
        .withdraw(...getWithdrawArguments(withdrawal, '0.00000000', signature));
      console.log((await result.wait()).gasUsed.toString());
    });
  });

  describe('Transfer', function () {
    it('with no outstanding funding payments', async function () {
      const transfer = {
        signatureHashVersion,
        nonce: uuidv1(),
        sourceWallet: trader1Wallet.address,
        destinationWallet: trader2Wallet.address,
        quantity: '1.00000000',
      };
      let signature = await trader1Wallet._signTypedData(
        ...getTransferSignatureTypedData(transfer, exchange.address),
      );

      await exchange
        .connect(dispatcherWallet)
        .transfer(...getTransferArguments(transfer, '0.00000000', signature));

      transfer.nonce = uuidv1();
      signature = await trader1Wallet._signTypedData(
        ...getTransferSignatureTypedData(transfer, exchange.address),
      );
      const result = await exchange
        .connect(dispatcherWallet)
        .transfer(...getTransferArguments(transfer, '0.00000000', signature));
      console.log((await result.wait()).gasUsed.toString());
    });
  });

  describe('index price publishing', async function () {
    it('for a single market', async () => {
      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPrice(indexPriceServiceWallet),
          ),
        ]);

      const result = await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPrice(indexPriceServiceWallet),
          ),
        ]);
      console.log((await result.wait()).gasUsed.toString());
    });

    it('for 5 markets', async () => {
      const baseAssetSymbols = ['XYZ1', 'XYZ2', 'XYZ3', 'XYZ4', 'XYZ5'];
      await Promise.all(
        baseAssetSymbols.map((symbol) =>
          addMarket(symbol, dispatcherWallet, exchange, marketStruct),
        ),
      );

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices(
          await Promise.all(
            baseAssetSymbols.map(async (symbol) =>
              indexPriceToArgumentStruct(
                await buildIndexPrice(indexPriceServiceWallet, symbol),
              ),
            ),
          ),
        );

      const result = await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices(
          await Promise.all(
            baseAssetSymbols.map(async (symbol) =>
              indexPriceToArgumentStruct(
                await buildIndexPrice(indexPriceServiceWallet, symbol),
              ),
            ),
          ),
        );
      console.log((await result.wait()).gasUsed.toString());
    });

    it('for 10 markets', async () => {
      const baseAssetSymbols = [
        'XYZ1',
        'XYZ2',
        'XYZ3',
        'XYZ4',
        'XYZ5',
        'XYZ6',
        'XYZ7',
        'XYZ8',
        'XYZ9',
        'XYZ10',
      ];
      await Promise.all(
        baseAssetSymbols.map((symbol) =>
          addMarket(symbol, dispatcherWallet, exchange, marketStruct),
        ),
      );

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices(
          await Promise.all(
            baseAssetSymbols.map(async (symbol) =>
              indexPriceToArgumentStruct(
                await buildIndexPrice(indexPriceServiceWallet, symbol),
              ),
            ),
          ),
        );

      const result = await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices(
          await Promise.all(
            baseAssetSymbols.map(async (symbol) =>
              indexPriceToArgumentStruct(
                await buildIndexPrice(indexPriceServiceWallet, symbol),
              ),
            ),
          ),
        );
      console.log((await result.wait()).gasUsed.toString());
    });

    it('for 20 markets', async () => {
      const baseAssetSymbols = [
        'XYZ1',
        'XYZ2',
        'XYZ3',
        'XYZ4',
        'XYZ5',
        'XYZ6',
        'XYZ7',
        'XYZ8',
        'XYZ9',
        'XYZ10',
        'XYZ11',
        'XYZ12',
        'XYZ13',
        'XYZ14',
        'XYZ15',
        'XYZ16',
        'XYZ17',
        'XYZ18',
        'XYZ19',
        'XYZ20',
      ];
      await Promise.all(
        baseAssetSymbols.map((symbol) =>
          addMarket(symbol, dispatcherWallet, exchange, marketStruct),
        ),
      );

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices(
          await Promise.all(
            baseAssetSymbols.map(async (symbol) =>
              indexPriceToArgumentStruct(
                await buildIndexPrice(indexPriceServiceWallet, symbol),
              ),
            ),
          ),
        );

      const result = await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices(
          await Promise.all(
            baseAssetSymbols.map(async (symbol) =>
              indexPriceToArgumentStruct(
                await buildIndexPrice(indexPriceServiceWallet, symbol),
              ),
            ),
          ),
        );
      console.log((await result.wait()).gasUsed.toString());
    });
  });

  describe('Trade', async function () {
    it('investigation', async () => {
      await fundWallets(
        [trader1Wallet, trader2Wallet],
        exchange,
        usdc,
        '8500.00000000',
      );

      await fundWallets(
        [insuranceFundWallet],
        exchange,
        usdc,
        '10000.00000000',
      );

      const baseAssetSymbols = ['XYZ1'];
      await Promise.all(
        baseAssetSymbols.map((symbol) =>
          addMarket(symbol, dispatcherWallet, exchange, marketStruct),
        ),
      );

      for (const symbol of baseAssetSymbols) {
        buyOrder.nonce = uuidv1();
        buyOrder.market = `${symbol}-USD`;
        buyOrderSignature = await trader2Wallet.signMessage(
          ethers.utils.arrayify(getOrderHash(buyOrder)),
        );

        sellOrder.nonce = uuidv1();
        sellOrder.market = `${symbol}-USD`;
        sellOrderSignature = await trader1Wallet.signMessage(
          ethers.utils.arrayify(getOrderHash(sellOrder)),
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
      }

      const trader3Wallet = (await ethers.getSigners())[10];
      await fundWallets([trader3Wallet], exchange, usdc);

      buyOrder.nonce = uuidv1();
      buyOrder.market = `${baseAssetSymbol}-USD`;
      buyOrder.wallet = trader3Wallet.address;
      buyOrderSignature = await trader3Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(buyOrder)),
      );

      sellOrder.nonce = uuidv1();
      sellOrder.market = `${baseAssetSymbol}-USD`;
      sellOrderSignature = await trader1Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(sellOrder)),
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

      console.log((await result!.wait()).gasUsed.toString());
    });

    it('with no outstanding funding payments and 5 open positions (limit-limit)', async () => {
      await fundWallets(
        [trader1Wallet, trader2Wallet],
        exchange,
        usdc,
        '8500.00000000',
      );

      await fundWallets(
        [insuranceFundWallet],
        exchange,
        usdc,
        '10000.00000000',
      );

      const baseAssetSymbols = ['XYZ1', 'XYZ2', 'XYZ3', 'XYZ4'];
      await Promise.all(
        baseAssetSymbols.map((symbol) =>
          addMarket(symbol, dispatcherWallet, exchange, marketStruct),
        ),
      );

      for (const symbol of baseAssetSymbols) {
        buyOrder.nonce = uuidv1();
        buyOrder.market = `${symbol}-USD`;
        buyOrderSignature = await trader2Wallet.signMessage(
          ethers.utils.arrayify(getOrderHash(buyOrder)),
        );

        sellOrder.nonce = uuidv1();
        sellOrder.market = `${symbol}-USD`;
        sellOrderSignature = await trader1Wallet.signMessage(
          ethers.utils.arrayify(getOrderHash(sellOrder)),
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
      }

      buyOrder.nonce = uuidv1();
      buyOrder.market = `${baseAssetSymbol}-USD`;
      buyOrderSignature = await trader2Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(buyOrder)),
      );

      sellOrder.nonce = uuidv1();
      sellOrder.market = `${baseAssetSymbol}-USD`;
      sellOrderSignature = await trader1Wallet.signMessage(
        ethers.utils.arrayify(getOrderHash(sellOrder)),
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

      console.log((await result!.wait()).gasUsed.toString());
    });

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
        1,
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
      await fundWallets(
        [trader1Wallet, trader2Wallet],
        exchange,
        usdc,
        '100000.00000000',
      );

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
      await fundWallets(
        [trader1Wallet, trader2Wallet],
        exchange,
        usdc,
        '100000.00000000',
      );

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
      await fundWallets(
        [trader1Wallet, trader2Wallet],
        exchange,
        usdc,
        '100000.00000000',
      );

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

    await time.increaseTo(nextFundingTimestampInMs / 1000);

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

async function addMarket(
  symbol: string,
  dispatcherWallet: SignerWithAddress,
  exchange: Exchange_v4,
  marketStruct: MarketStruct,
) {
  const newMarketStruct = { ...marketStruct, baseAssetSymbol: symbol };

  await exchange.addMarket(newMarketStruct);
  await exchange.connect(dispatcherWallet).activateMarket(symbol);
}
