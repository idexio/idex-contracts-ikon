import { ethers } from 'hardhat';
import { mine } from '@nomicfoundation/hardhat-network-helpers';
import { decimalToPips, IndexPrice, indexPriceToArgumentStruct } from '../lib';

import type { Exchange_v4, Governance, USDC } from '../typechain-types';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import {
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
  });

  describe('deleverageInsuranceFundClosure', async function () {
    let counterpartyWallet: SignerWithAddress;
    let insuranceWallet: SignerWithAddress;

    beforeEach(async () => {
      const results = await bootstrapLiquidatedWallet();
      counterpartyWallet = results.counterpartyWallet;
      exchange = results.exchange;
      insuranceWallet = results.insuranceWallet;
    });

    it('should work for valid wallet', async function () {
      await exchange.connect(dispatcherWallet).deleverageInsuranceFundClosure({
        baseAssetSymbol,
        counterpartyWallet: counterpartyWallet.address,
        liquidatingWallet: insuranceWallet.address,
        liquidationBaseQuantity: decimalToPips('10.00000000'),
        liquidationQuoteQuantity: decimalToPips('21980.00000000'),
      });
    });

    it('should revert when not sent by dispatcher', async function () {
      await expect(
        exchange.deleverageInsuranceFundClosure({
          baseAssetSymbol,
          counterpartyWallet: counterpartyWallet.address,
          liquidatingWallet: insuranceWallet.address,
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
          liquidatingWallet: insuranceWallet.address,
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('21980.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/no active market found/i);
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
          liquidatingWallet: insuranceWallet.address,
          liquidationBaseQuantity: decimalToPips('10.00000000'),
          liquidationQuoteQuantity: decimalToPips('20080.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/invalid quote quantity/i);
    });
  });

  describe('deleverageExitAcquisition', async function () {
    it('should work for valid wallet', async function () {
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
