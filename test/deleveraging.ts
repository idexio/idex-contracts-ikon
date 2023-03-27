import { mine } from '@nomicfoundation/hardhat-network-helpers';
import { ethers, network } from 'hardhat';

import { decimalToPips, IndexPrice, indexPriceToArgumentStruct } from '../lib';

import type {
  ChainlinkAggregatorMock,
  Exchange_v4,
  Governance,
  USDC,
} from '../typechain-types';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import {
  addAndActivateMarket,
  baseAssetSymbol,
  bootstrapLiquidatedWallet,
  buildIndexPrice,
  buildIndexPriceWithValue,
  deployAndAssociateContracts,
  executeTrade,
  expect,
  fieldUpgradeDelayInBlocks,
  fundWallets,
  quoteAssetSymbol,
} from './helpers';

// TODO Partial deleveraging
describe('Exchange', function () {
  let chainlinkAggregator: ChainlinkAggregatorMock;
  let exchange: Exchange_v4;
  let exitFundWallet: SignerWithAddress;
  let governance: Governance;
  let indexPrice: IndexPrice;
  let indexPriceServiceWallet: SignerWithAddress;
  let insuranceFundWallet: SignerWithAddress;
  let ownerWallet: SignerWithAddress;
  let dispatcherWallet: SignerWithAddress;
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
    chainlinkAggregator = results.chainlinkAggregator;
    exchange = results.exchange;
    governance = results.governance;
    usdc = results.usdc;

    await results.usdc.faucet(dispatcherWallet.address);

    await fundWallets([trader1Wallet, trader2Wallet], exchange, results.usdc);

    indexPrice = await buildIndexPrice(indexPriceServiceWallet);

    await executeTrade(
      exchange,
      dispatcherWallet,
      indexPrice,
      trader1Wallet,
      trader2Wallet,
    );
  });

  describe('deleverageInMaintenanceAcquisition', async function () {
    it('should work for valid wallet when IF cannot acquire within margin limits', async function () {
      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPriceWithValue(
              indexPriceServiceWallet,
              '2150.00000000',
            ),
          ),
        ]);

      await exchange
        .connect(dispatcherWallet)
        .deleverageInMaintenanceAcquisition({
          baseAssetSymbol,
          counterpartyWallet: trader2Wallet.address,
          liquidatingWallet: trader1Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '21980.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        });
    });

    it('should work for valid wallet when IF has open position and cannot acquire within margin limits', async function () {
      const wallets = await ethers.getSigners();
      const trader3Wallet = wallets[10];
      const trader4Wallet = wallets[11];
      await fundWallets([trader3Wallet, trader4Wallet], exchange, usdc);
      await executeTrade(
        exchange,
        dispatcherWallet,
        await buildIndexPrice(indexPriceServiceWallet),
        trader3Wallet,
        trader4Wallet,
      );
      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPriceWithValue(
              indexPriceServiceWallet,
              '1850.00000000',
            ),
          ),
        ]);
      await fundWallets([insuranceFundWallet], exchange, usdc, '902.00000000');
      await exchange.connect(dispatcherWallet).liquidateWalletInMaintenance({
        counterpartyWallet: insuranceFundWallet.address,
        liquidatingWallet: trader4Wallet.address,
        liquidationQuoteQuantities: ['18040.00000000'].map(decimalToPips),
      });

      const overrides = {
        initialMarginFraction: '100000000',
        maintenanceMarginFraction: '3000000',
        incrementalInitialMarginFraction: '1000000',
        baselinePositionSize: '14000000000',
        incrementalPositionSize: '2800000000',
        maximumPositionSize: '282000000000',
        minimumPositionSize: '10000000',
      };
      await governance
        .connect(ownerWallet)
        .initiateMarketOverridesUpgrade(
          baseAssetSymbol,
          overrides,
          insuranceFundWallet.address,
        );
      await mine(fieldUpgradeDelayInBlocks, { interval: 0 });
      await governance
        .connect(dispatcherWallet)
        .finalizeMarketOverridesUpgrade(
          baseAssetSymbol,
          overrides,
          insuranceFundWallet.address,
        );

      await addAndActivateMarket(
        chainlinkAggregator,
        dispatcherWallet,
        exchange,
        'BTC',
      );
      await fundWallets(
        [trader1Wallet, trader2Wallet],
        exchange,
        usdc,
        '51000.00000000',
      );

      await executeTrade(
        exchange,
        dispatcherWallet,
        await buildIndexPriceWithValue(
          indexPriceServiceWallet,
          '24000.00000000',
          'BTC',
        ),
        trader1Wallet,
        trader2Wallet,
        'BTC',
        '24000.00000000',
      );

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPriceWithValue(
              indexPriceServiceWallet,
              '29000.00000000',
              'BTC',
            ),
          ),
        ]);

      await exchange
        .connect(dispatcherWallet)
        .deleverageInMaintenanceAcquisition({
          baseAssetSymbol,
          counterpartyWallet: trader2Wallet.address,
          liquidatingWallet: trader1Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '18767.45542949',
            '294192.54457050',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('18767.45542949'),
        });
    });

    it('should work for valid wallet when IF cannot acquire within maximum position size', async function () {
      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPriceWithValue(
              indexPriceServiceWallet,
              '2150.00000000',
            ),
          ),
        ]);

      await fundWallets(
        [insuranceFundWallet],
        exchange,
        usdc,
        '22000.00000000',
      );
      const marketOverrides = {
        initialMarginFraction: '3000000',
        maintenanceMarginFraction: '1000000',
        incrementalInitialMarginFraction: '1000000',
        baselinePositionSize: '14000000000',
        incrementalPositionSize: '2800000000',
        maximumPositionSize: '100000000',
        minimumPositionSize: '10000000',
      };
      await governance.initiateMarketOverridesUpgrade(
        baseAssetSymbol,
        marketOverrides,
        insuranceFundWallet.address,
      );
      await mine(fieldUpgradeDelayInBlocks, { interval: 0 });
      await governance.finalizeMarketOverridesUpgrade(
        baseAssetSymbol,
        marketOverrides,
        insuranceFundWallet.address,
      );

      await exchange
        .connect(dispatcherWallet)
        .deleverageInMaintenanceAcquisition({
          baseAssetSymbol,
          counterpartyWallet: trader2Wallet.address,
          liquidatingWallet: trader1Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '21980.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        });
    });

    it('should revert when not sent by dispatcher', async function () {
      await expect(
        exchange.deleverageInMaintenanceAcquisition({
          baseAssetSymbol,
          counterpartyWallet: trader2Wallet.address,
          liquidatingWallet: trader1Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '21980.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/caller must be dispatcher/i);
    });

    it('should revert when not in maintenance', async function () {
      await expect(
        exchange.connect(dispatcherWallet).deleverageInMaintenanceAcquisition({
          baseAssetSymbol,
          counterpartyWallet: trader2Wallet.address,
          liquidatingWallet: trader1Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '21980.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/maintenance margin requirement met/i);
    });

    it('should revert when IF can acquire', async function () {
      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPriceWithValue(
              indexPriceServiceWallet,
              '2150.00000000',
            ),
          ),
        ]);

      await fundWallets(
        [insuranceFundWallet],
        exchange,
        usdc,
        '22000.00000000',
      );

      await expect(
        exchange.connect(dispatcherWallet).deleverageInMaintenanceAcquisition({
          baseAssetSymbol,
          counterpartyWallet: trader2Wallet.address,
          liquidatingWallet: trader1Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '21980.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/insurance fund can acquire/i);
    });

    it('should revert when wallet has no open position', async function () {
      await expect(
        exchange.connect(dispatcherWallet).deleverageInMaintenanceAcquisition({
          baseAssetSymbol: 'XYZ',
          counterpartyWallet: trader2Wallet.address,
          liquidatingWallet: trader1Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '21980.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/no open position in market/i);
    });

    it('should revert when liquidating EF', async function () {
      await expect(
        exchange.connect(dispatcherWallet).deleverageInMaintenanceAcquisition({
          baseAssetSymbol,
          counterpartyWallet: trader2Wallet.address,
          liquidatingWallet: exitFundWallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '21980.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/cannot liquidate EF/i);
    });

    it('should revert when liquidating IF', async function () {
      await expect(
        exchange.connect(dispatcherWallet).deleverageInMaintenanceAcquisition({
          baseAssetSymbol,
          counterpartyWallet: trader2Wallet.address,
          liquidatingWallet: insuranceFundWallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '21980.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/cannot liquidate IF/i);
    });

    it('should revert when liquidating wallet against itself', async function () {
      await expect(
        exchange.connect(dispatcherWallet).deleverageInMaintenanceAcquisition({
          baseAssetSymbol,
          counterpartyWallet: trader1Wallet.address,
          liquidatingWallet: trader1Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '21980.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        }),
      ).to.eventually.be.rejectedWith(
        /cannot liquidate wallet against itself/i,
      );
    });

    it('should revert when deleveraging EF', async function () {
      await expect(
        exchange.connect(dispatcherWallet).deleverageInMaintenanceAcquisition({
          baseAssetSymbol,
          counterpartyWallet: exitFundWallet.address,
          liquidatingWallet: trader1Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '21980.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/cannot deleverage EF/i);
    });

    it('should revert when deleveraging IF', async function () {
      await expect(
        exchange.connect(dispatcherWallet).deleverageInMaintenanceAcquisition({
          baseAssetSymbol,
          counterpartyWallet: insuranceFundWallet.address,
          liquidatingWallet: trader1Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '21980.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/cannot deleverage IF/i);
    });
  });

  describe('deleverageInsuranceFundClosure', async function () {
    let counterpartyWallet: SignerWithAddress;
    let insuranceFundWallet: SignerWithAddress;

    beforeEach(async () => {
      const results = await bootstrapLiquidatedWallet();
      counterpartyWallet = results.counterpartyWallet;
      exchange = results.exchange;
      insuranceFundWallet = results.insuranceFundWallet;
    });

    it('should work for valid wallet', async function () {
      await exchange.connect(dispatcherWallet).deleverageInsuranceFundClosure({
        baseAssetSymbol,
        counterpartyWallet: counterpartyWallet.address,
        liquidatingWallet: insuranceFundWallet.address,
        liquidationBaseQuantity: decimalToPips('10.00000000'),
        liquidationQuoteQuantity: decimalToPips('21980.00000000'),
      });
    });

    it('should revert when not sent by dispatcher', async function () {
      await expect(
        exchange.deleverageInsuranceFundClosure({
          baseAssetSymbol,
          counterpartyWallet: counterpartyWallet.address,
          liquidatingWallet: insuranceFundWallet.address,
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/caller must be dispatcher/i);
    });

    it('should revert for invalid market', async function () {
      await expect(
        exchange.connect(dispatcherWallet).deleverageInsuranceFundClosure({
          baseAssetSymbol: 'XYZ',
          counterpartyWallet: counterpartyWallet.address,
          liquidatingWallet: insuranceFundWallet.address,
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/no active market found/i);
    });

    it('should revert when wallet has no open position', async function () {
      await exchange.connect(dispatcherWallet).deleverageInsuranceFundClosure({
        baseAssetSymbol,
        counterpartyWallet: counterpartyWallet.address,
        liquidatingWallet: insuranceFundWallet.address,
        liquidationBaseQuantity: decimalToPips('10.00000000'),
        liquidationQuoteQuantity: decimalToPips('21980.00000000'),
      }),
        await expect(
          exchange.connect(dispatcherWallet).deleverageInsuranceFundClosure({
            baseAssetSymbol,
            counterpartyWallet: counterpartyWallet.address,
            liquidatingWallet: insuranceFundWallet.address,
            liquidationBaseQuantity: decimalToPips('10.00000000'),
            liquidationQuoteQuantity: decimalToPips('21980.00000000'),
          }),
        ).to.eventually.be.rejectedWith(/open position not found for market/i);
    });

    it('should revert when wallet is deleveraged against itself', async function () {
      await exchange.connect(trader1Wallet).exitWallet();

      await expect(
        exchange.connect(dispatcherWallet).deleverageInsuranceFundClosure({
          baseAssetSymbol,
          counterpartyWallet: counterpartyWallet.address,
          liquidatingWallet: counterpartyWallet.address,
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        }),
      ).to.eventually.be.rejectedWith(
        /cannot liquidate wallet against itself/i,
      );
    });

    it('should revert when EF is deleveraged', async function () {
      await exchange.connect(trader1Wallet).exitWallet();

      await expect(
        exchange.connect(dispatcherWallet).deleverageInsuranceFundClosure({
          baseAssetSymbol,
          counterpartyWallet: exitFundWallet.address,
          liquidatingWallet: counterpartyWallet.address,
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/cannot deleverage EF/i);
    });

    it('should revert when IF is deleveraged', async function () {
      await exchange.connect(trader1Wallet).exitWallet();

      await expect(
        exchange.connect(dispatcherWallet).deleverageInsuranceFundClosure({
          baseAssetSymbol,
          counterpartyWallet: insuranceFundWallet.address,
          liquidatingWallet: counterpartyWallet.address,
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/cannot deleverage IF/i);
    });

    it('should revert when IF is not liquidated', async function () {
      await expect(
        exchange.connect(dispatcherWallet).deleverageInsuranceFundClosure({
          baseAssetSymbol,
          counterpartyWallet: counterpartyWallet.address,
          liquidatingWallet: trader1Wallet.address,
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/liquidating wallet must be IF/i);
    });

    it('should revert for invalid quote quantity', async function () {
      await expect(
        exchange.connect(dispatcherWallet).deleverageInsuranceFundClosure({
          baseAssetSymbol,
          counterpartyWallet: counterpartyWallet.address,
          liquidatingWallet: insuranceFundWallet.address,
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('20080.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/invalid quote quantity/i);
    });
  });

  describe('deleverageExitAcquisition', async function () {
    it('should work for valid wallet with long position', async function () {
      await exchange.connect(trader2Wallet).exitWallet();

      await exchange.connect(dispatcherWallet).deleverageExitAcquisition({
        baseAssetSymbol,
        counterpartyWallet: trader1Wallet.address,
        liquidatingWallet: trader2Wallet.address,
        validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
          '20000.00000000',
        ].map(decimalToPips),
        liquidationBaseQuantity: decimalToPips('10.00000000'),
        liquidationQuoteQuantity: decimalToPips('20000.00000000'),
      });
    });

    it('should work for valid wallet with short position', async function () {
      await exchange.connect(trader1Wallet).exitWallet();

      await exchange.connect(dispatcherWallet).deleverageExitAcquisition({
        baseAssetSymbol,
        counterpartyWallet: trader2Wallet.address,
        liquidatingWallet: trader1Wallet.address,
        validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
          '20000.00000000',
        ].map(decimalToPips),
        liquidationBaseQuantity: decimalToPips('10.00000000'),
        liquidationQuoteQuantity: decimalToPips('20000.00000000'),
      });
    });

    it('should maintain pricing strategy when account value stays positive', async function () {
      await fundWallets(
        [trader1Wallet, trader2Wallet],
        exchange,
        usdc,
        '1000.00000000',
      );

      await exchange.addMarket({
        exists: true,
        isActive: false,
        baseAssetSymbol: 'BTC',
        chainlinkPriceFeedAddress: chainlinkAggregator.address,
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
      });
      await exchange.connect(dispatcherWallet).activateMarket('BTC');

      await executeTrade(
        exchange,
        dispatcherWallet,
        await buildIndexPrice(indexPriceServiceWallet, 'BTC'),
        trader1Wallet,
        trader2Wallet,
        'BTC',
      );

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPriceWithValue(
              indexPriceServiceWallet,
              '2150.00000000',
            ),
          ),
        ]);

      let startQuoteBalance = (
        await exchange.loadBalanceBySymbol(trader2Wallet.address, 'USD')
      ).toString();
      let ethCostBasis = (
        await exchange.loadBalanceStructBySymbol(trader2Wallet.address, 'ETH')
      ).costBasis.toString();

      await exchange.connect(trader2Wallet).exitWallet();

      await exchange.connect(dispatcherWallet).deleverageExitAcquisition({
        baseAssetSymbol,
        counterpartyWallet: trader1Wallet.address,
        liquidatingWallet: trader2Wallet.address,
        validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
          '20000.00000000',
          '20000.00000000',
        ].map(decimalToPips),
        liquidationBaseQuantity: decimalToPips('10.00000000'),
        liquidationQuoteQuantity: decimalToPips('20000.00000000'),
      });

      // Cost basis is now worse than index price
      expect(
        (
          await exchange.loadBalanceBySymbol(trader2Wallet.address, 'USD')
        ).toString(),
      ).to.equal((BigInt(startQuoteBalance) + BigInt(ethCostBasis)).toString());

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPriceWithValue(
              indexPriceServiceWallet,
              '1850.00000000',
              'BTC',
            ),
          ),
        ]);

      startQuoteBalance = (
        await exchange.loadBalanceBySymbol(trader2Wallet.address, 'USD')
      ).toString();

      await exchange.connect(dispatcherWallet).deleverageExitAcquisition({
        baseAssetSymbol: 'BTC',
        counterpartyWallet: trader1Wallet.address,
        liquidatingWallet: trader2Wallet.address,
        validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
          '18500.00000000',
        ].map(decimalToPips),
        liquidationBaseQuantity: decimalToPips('10.00000000'),
        liquidationQuoteQuantity: decimalToPips('18500.00000000'),
      });

      // Index price is now worse than cost basis
      expect(
        (
          await exchange.loadBalanceBySymbol(trader2Wallet.address, 'USD')
        ).toString(),
      ).to.equal(
        (
          BigInt(startQuoteBalance) + BigInt(decimalToPips('18500.00000000'))
        ).toString(),
      );
    });

    it('should maintain pricing strategy when account value goes negative to positive', async function () {
      await fundWallets(
        [trader1Wallet, trader2Wallet],
        exchange,
        usdc,
        '1000.00000000',
      );

      await exchange.addMarket({
        exists: true,
        isActive: false,
        baseAssetSymbol: 'BTC',
        chainlinkPriceFeedAddress: chainlinkAggregator.address,
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
      });
      await exchange.connect(dispatcherWallet).activateMarket('BTC');

      await executeTrade(
        exchange,
        dispatcherWallet,
        await buildIndexPrice(indexPriceServiceWallet, 'BTC'),
        trader1Wallet,
        trader2Wallet,
        'BTC',
      );

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPriceWithValue(
              indexPriceServiceWallet,
              '1000.00000000',
            ),
          ),
        ]);

      await exchange.connect(trader2Wallet).exitWallet();

      await exchange.connect(dispatcherWallet).deleverageExitAcquisition({
        baseAssetSymbol,
        counterpartyWallet: trader1Wallet.address,
        liquidatingWallet: trader2Wallet.address,
        validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
          '12360.00000000',
          '24720.00000000',
        ].map(decimalToPips),
        liquidationBaseQuantity: decimalToPips('10.00000000'),
        liquidationQuoteQuantity: decimalToPips('12360.00000000'),
      });

      await exchange.connect(dispatcherWallet).deleverageExitAcquisition({
        baseAssetSymbol: 'BTC',
        counterpartyWallet: trader1Wallet.address,
        liquidatingWallet: trader2Wallet.address,
        validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
          '24720.00000000',
        ].map(decimalToPips),
        liquidationBaseQuantity: decimalToPips('10.00000000'),
        liquidationQuoteQuantity: decimalToPips('24720.00000000'),
      });

      expect(
        (
          await exchange.loadBalanceBySymbol(trader2Wallet.address, 'USD')
        ).toString(),
      ).to.equal('0');
      expect(
        (
          await exchange.loadBalanceBySymbol(trader2Wallet.address, 'ETH')
        ).toString(),
      ).to.equal('0');
      expect(
        (
          await exchange.loadBalanceBySymbol(trader2Wallet.address, 'BTC')
        ).toString(),
      ).to.equal('0');
    });

    it('should change pricing strategy when account value goes positive to negative', async function () {
      await fundWallets(
        [trader1Wallet, trader2Wallet],
        exchange,
        usdc,
        '1000.00000000',
      );

      await exchange.addMarket({
        exists: true,
        isActive: false,
        baseAssetSymbol: 'BTC',
        chainlinkPriceFeedAddress: chainlinkAggregator.address,
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
      });
      await exchange.connect(dispatcherWallet).activateMarket('BTC');

      await executeTrade(
        exchange,
        dispatcherWallet,
        await buildIndexPrice(indexPriceServiceWallet, 'BTC'),
        trader1Wallet,
        trader2Wallet,
        'BTC',
      );

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPriceWithValue(
              indexPriceServiceWallet,
              '2150.00000000',
            ),
          ),
        ]);

      const startQuoteBalance = (
        await exchange.loadBalanceBySymbol(trader2Wallet.address, 'USD')
      ).toString();
      const ethCostBasis = (
        await exchange.loadBalanceStructBySymbol(trader2Wallet.address, 'ETH')
      ).costBasis.toString();

      await exchange.connect(trader2Wallet).exitWallet();

      await exchange.connect(dispatcherWallet).deleverageExitAcquisition({
        baseAssetSymbol,
        counterpartyWallet: trader1Wallet.address,
        liquidatingWallet: trader2Wallet.address,
        validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
          '20000.00000000',
          '20000.00000000',
        ].map(decimalToPips),
        liquidationBaseQuantity: decimalToPips('10.00000000'),
        liquidationQuoteQuantity: decimalToPips('20000.00000000'),
      });

      // Cost basis is now worse than index price
      expect(
        (
          await exchange.loadBalanceBySymbol(trader2Wallet.address, 'USD')
        ).toString(),
      ).to.equal((BigInt(startQuoteBalance) + BigInt(ethCostBasis)).toString());

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPriceWithValue(
              indexPriceServiceWallet,
              '1000.00000000',
              'BTC',
            ),
          ),
        ]);

      const remainingQuoteBalance = (
        await exchange.loadBalanceBySymbol(trader2Wallet.address, 'USD')
      ).toString();

      await exchange.connect(dispatcherWallet).deleverageExitAcquisition({
        baseAssetSymbol: 'BTC',
        counterpartyWallet: trader1Wallet.address,
        liquidatingWallet: trader2Wallet.address,
        validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
          (BigInt(remainingQuoteBalance) * BigInt(-1)).toString(),
        ],
        liquidationBaseQuantity: decimalToPips('10.00000000'),
        liquidationQuoteQuantity: (
          BigInt(remainingQuoteBalance) * BigInt(-1)
        ).toString(),
      });

      expect(
        (
          await exchange.loadBalanceBySymbol(trader2Wallet.address, 'USD')
        ).toString(),
      ).to.equal('0');
      expect(
        (
          await exchange.loadBalanceBySymbol(trader2Wallet.address, 'ETH')
        ).toString(),
      ).to.equal('0');
      expect(
        (
          await exchange.loadBalanceBySymbol(trader2Wallet.address, 'BTC')
        ).toString(),
      ).to.equal('0');
    });

    it('should revert when not sent by dispatcher', async function () {
      await exchange.connect(trader2Wallet).exitWallet();

      await expect(
        exchange.deleverageExitAcquisition({
          baseAssetSymbol,
          counterpartyWallet: trader1Wallet.address,
          liquidatingWallet: trader2Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '20000.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/caller must be dispatcher/i);
    });

    it('should revert when wallet not exited', async function () {
      await expect(
        exchange.connect(dispatcherWallet).deleverageExitAcquisition({
          baseAssetSymbol,
          counterpartyWallet: trader1Wallet.address,
          liquidatingWallet: trader2Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '20000.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/wallet not exited/i);
    });

    it('should revert for invalid quote quantity', async function () {
      await exchange.connect(trader2Wallet).exitWallet();

      await expect(
        exchange.connect(dispatcherWallet).deleverageExitAcquisition({
          baseAssetSymbol,
          counterpartyWallet: trader1Wallet.address,
          liquidatingWallet: trader2Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '20000.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('19000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/invalid quote quantity/i);
    });

    it('should revert when wallet is deleveraged against itself', async function () {
      await exchange.connect(trader1Wallet).exitWallet();

      await expect(
        exchange.connect(dispatcherWallet).deleverageExitAcquisition({
          baseAssetSymbol,
          counterpartyWallet: trader1Wallet.address,
          liquidatingWallet: trader1Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '20000.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(
        /cannot liquidate wallet against itself/i,
      );
    });

    it('should revert when EF is deleveraged', async function () {
      await exchange.connect(trader1Wallet).exitWallet();

      await expect(
        exchange.connect(dispatcherWallet).deleverageExitAcquisition({
          baseAssetSymbol,
          counterpartyWallet: exitFundWallet.address,
          liquidatingWallet: trader1Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '20000.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/cannot deleverage EF/i);
    });

    it('should revert when IF is deleveraged', async function () {
      await exchange.connect(trader1Wallet).exitWallet();

      await expect(
        exchange.connect(dispatcherWallet).deleverageExitAcquisition({
          baseAssetSymbol,
          counterpartyWallet: insuranceFundWallet.address,
          liquidatingWallet: trader1Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '20000.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/cannot deleverage IF/i);
    });

    it('should revert when wallet does not have open position in market', async function () {
      await exchange.connect(trader2Wallet).exitWallet();

      await expect(
        exchange.connect(dispatcherWallet).deleverageExitAcquisition({
          baseAssetSymbol: 'XYZ',
          counterpartyWallet: trader1Wallet.address,
          liquidatingWallet: trader2Wallet.address,
          validateInsuranceFundCannotLiquidateWalletQuoteQuantities: [
            '20000.00000000',
          ].map(decimalToPips),
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/no open position in market/i);
    });
  });

  describe('deleverageExitFundClosure', async function () {
    it('should work for open long position', async function () {
      await exchange.connect(trader1Wallet).exitWallet();
      await exchange.withdrawExit(trader1Wallet.address);

      await exchange.connect(dispatcherWallet).deleverageExitFundClosure({
        baseAssetSymbol,
        counterpartyWallet: trader2Wallet.address,
        liquidatingWallet: exitFundWallet.address,
        liquidationBaseQuantity: decimalToPips('10.00000000'),
        liquidationQuoteQuantity: decimalToPips('20000.00000000'),
      });
    });

    it('should work for open short position', async function () {
      await exchange.connect(trader2Wallet).exitWallet();
      await exchange.withdrawExit(trader2Wallet.address);

      await exchange.connect(dispatcherWallet).deleverageExitFundClosure({
        baseAssetSymbol,
        counterpartyWallet: trader1Wallet.address,
        liquidatingWallet: exitFundWallet.address,
        liquidationBaseQuantity: decimalToPips('10.00000000'),
        liquidationQuoteQuantity: decimalToPips('20000.00000000'),
      });
    });

    it('should work for open short position and negative total account value', async function () {
      await exchange.connect(trader2Wallet).exitWallet();
      await exchange.withdrawExit(trader2Wallet.address);

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPriceWithValue(
              indexPriceServiceWallet,
              '1850.00000000',
              baseAssetSymbol,
            ),
          ),
        ]);

      await exchange.connect(dispatcherWallet).deleverageExitFundClosure({
        baseAssetSymbol,
        counterpartyWallet: trader1Wallet.address,
        liquidatingWallet: exitFundWallet.address,
        liquidationBaseQuantity: decimalToPips('10.00000000'),
        liquidationQuoteQuantity: decimalToPips('20000.00000000'),
      });
    });

    it('should zero out after closing all open positions', async function () {
      await exchange.connect(trader1Wallet).exitWallet();
      await exchange.withdrawExit(trader1Wallet.address);

      await exchange.connect(trader2Wallet).exitWallet();
      await exchange.withdrawExit(trader2Wallet.address);

      expect(
        (
          await exchange.loadBalanceBySymbol(
            exitFundWallet.address,
            baseAssetSymbol,
          )
        ).toString(),
      ).to.equal('0');
      expect(
        (
          await exchange.loadBalanceBySymbol(
            exitFundWallet.address,
            quoteAssetSymbol,
          )
        ).toString(),
      ).to.equal('0');
    });

    it('should work for open short position and negative account value', async function () {
      await exchange.connect(trader2Wallet).exitWallet();
      await exchange.withdrawExit(trader2Wallet.address);

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

      await exchange.connect(dispatcherWallet).deleverageExitFundClosure({
        baseAssetSymbol,
        counterpartyWallet: trader1Wallet.address,
        liquidatingWallet: exitFundWallet.address,
        liquidationBaseQuantity: decimalToPips('10.00000000'),
        liquidationQuoteQuantity: decimalToPips('21500.00000000'),
      });
    });

    it('should work for quote quantities below validation threshold', async function () {
      await exchange.connect(trader1Wallet).exitWallet();
      await exchange.withdrawExit(trader1Wallet.address);

      await exchange.connect(dispatcherWallet).deleverageExitFundClosure({
        baseAssetSymbol,
        counterpartyWallet: trader2Wallet.address,
        liquidatingWallet: exitFundWallet.address,
        liquidationBaseQuantity: decimalToPips('9.99999999'),
        liquidationQuoteQuantity: decimalToPips('19999.99998000'),
      });

      await exchange.connect(dispatcherWallet).deleverageExitFundClosure({
        baseAssetSymbol,
        counterpartyWallet: trader2Wallet.address,
        liquidatingWallet: exitFundWallet.address,
        liquidationBaseQuantity: decimalToPips('0.00000001'),
        liquidationQuoteQuantity: decimalToPips('0.00000629'),
      });
    });

    it('should revert when expected quote quantity is below validation threshold but provided quote quantity is not', async function () {
      await exchange.connect(trader1Wallet).exitWallet();
      await exchange.withdrawExit(trader1Wallet.address);

      await exchange.connect(dispatcherWallet).deleverageExitFundClosure({
        baseAssetSymbol,
        counterpartyWallet: trader2Wallet.address,
        liquidatingWallet: exitFundWallet.address,
        liquidationBaseQuantity: decimalToPips('9.99999999'),
        liquidationQuoteQuantity: decimalToPips('19999.99998000'),
      });

      await expect(
        exchange.connect(dispatcherWallet).deleverageExitFundClosure({
          baseAssetSymbol,
          counterpartyWallet: trader2Wallet.address,
          liquidatingWallet: exitFundWallet.address,
          liquidationBaseQuantity: decimalToPips('0.00000001'),
          liquidationQuoteQuantity: decimalToPips('0.10000000'),
        }),
      ).to.eventually.be.rejectedWith(/invalid quote quantity/i);
    });

    it('should revert when not sent by dispatcher', async function () {
      await expect(
        exchange.deleverageExitFundClosure({
          baseAssetSymbol,
          counterpartyWallet: trader2Wallet.address,
          liquidatingWallet: exitFundWallet.address,
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/caller must be dispatcher/i);
    });

    it('should revert for invalid quote quantity', async function () {
      await exchange.connect(trader1Wallet).exitWallet();
      await exchange.withdrawExit(trader1Wallet.address);

      await expect(
        exchange.connect(dispatcherWallet).deleverageExitFundClosure({
          baseAssetSymbol,
          counterpartyWallet: trader2Wallet.address,
          liquidatingWallet: exitFundWallet.address,
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('10000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/invalid quote quantity/i);
    });

    it('should revert when EF is not liquidated', async function () {
      await exchange.connect(trader1Wallet).exitWallet();
      await exchange.withdrawExit(trader1Wallet.address);

      await expect(
        exchange.connect(dispatcherWallet).deleverageExitFundClosure({
          baseAssetSymbol,
          counterpartyWallet: trader2Wallet.address,
          liquidatingWallet: insuranceFundWallet.address,
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/liquidating wallet must be EF/i);
    });
  });
});
