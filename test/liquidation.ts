import BigNumber from 'bignumber.js';
import { mine } from '@nomicfoundation/hardhat-network-helpers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { ethers, network } from 'hardhat';

import type {
  Exchange_v4,
  Governance,
  LiquidationValidationsMock,
  USDC,
} from '../typechain-types';
import { decimalToPips, IndexPrice, indexPriceToArgumentStruct } from '../lib';
import {
  baseAssetSymbol,
  buildIndexPrice,
  buildIndexPriceWithValue,
  deployAndAssociateContracts,
  executeTrade,
  expect,
  fundWallets,
} from './helpers';

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

    await results.usdc.faucet(dispatcherWallet.address);

    await fundWallets([trader1Wallet, trader2Wallet], exchange, usdc);

    indexPrice = await buildIndexPrice(indexPriceServiceWallet);

    await executeTrade(
      exchange,
      dispatcherWallet,
      indexPrice,
      trader1Wallet,
      trader2Wallet,
    );
  });

  describe('calculateQuoteQuantityAtBankruptcyPrice', async function () {
    let liquidationValidationsMock: LiquidationValidationsMock;

    beforeEach(async () => {
      liquidationValidationsMock = await (
        await ethers.getContractFactory('LiquidationValidationsMock')
      ).deploy();
    });

    it('should revert if result overflows int64', async function () {
      await expect(
        liquidationValidationsMock.calculateQuoteQuantityAtBankruptcyPrice(
          new BigNumber(2).pow(63).minus(1).toString(),
          '3000000',
          new BigNumber(2).pow(63).minus(1).toString(),
          '10000000',
          '3000000',
        ),
      ).to.eventually.be.rejectedWith(/pip quantity overflows int64/i);
    });

    it('should revert if result underflows int64', async function () {
      await expect(
        liquidationValidationsMock.calculateQuoteQuantityAtBankruptcyPrice(
          new BigNumber(2).pow(63).minus(1).toString(),
          '3000000',
          new BigNumber(2).pow(63).negated().toString(),
          '10000000',
          '3000000',
        ),
      ).to.eventually.be.rejectedWith(/pip quantity underflows int64/i);
    });
  });

  describe('liquidatePositionBelowMinimum', async function () {
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
    });

    it('should work for valid wallet', async function () {
      await fundWallets([insuranceFundWallet], exchange, usdc);

      await exchange.connect(dispatcherWallet).liquidatePositionBelowMinimum({
        baseAssetSymbol,
        liquidatingWallet: trader1Wallet.address,
        liquidationQuoteQuantity: decimalToPips('20000.00000000'),
      });
    });

    it('should work for valid wallet with quote below validation threshold', async function () {
      await fundWallets([insuranceFundWallet], exchange, usdc);
      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPriceWithValue(
              indexPriceServiceWallet,
              '0.00000100',
              baseAssetSymbol,
            ),
          ),
        ]);

      await exchange.connect(dispatcherWallet).liquidatePositionBelowMinimum({
        baseAssetSymbol,
        liquidatingWallet: trader1Wallet.address,
        liquidationQuoteQuantity: decimalToPips('0.00007213'),
      });
    });

    it('should revert when not sent by dispatcher', async function () {
      await expect(
        exchange.liquidatePositionBelowMinimum({
          baseAssetSymbol,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/caller must be dispatcher wallet/i);
    });

    it('should revert when position is above minimum', async function () {
      const overrides = {
        initialMarginFraction: '5000000',
        maintenanceMarginFraction: '3000000',
        incrementalInitialMarginFraction: '1000000',
        baselinePositionSize: '14000000000',
        incrementalPositionSize: '2800000000',
        maximumPositionSize: '282000000000',
        minimumPositionSize: '100000000',
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
        exchange.connect(dispatcherWallet).liquidatePositionBelowMinimum({
          baseAssetSymbol,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/position size above minimum/i);
    });

    it('should revert when wallet is in maintenance', async function () {
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

      await expect(
        exchange.connect(dispatcherWallet).liquidatePositionBelowMinimum({
          baseAssetSymbol,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(
        /maintenance margin requirement not met/i,
      );
    });

    it('should revert for invalid quote value', async function () {
      await expect(
        exchange.connect(dispatcherWallet).liquidatePositionBelowMinimum({
          baseAssetSymbol,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantity: decimalToPips('2000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/invalid liquidation quote quantity/i);
    });

    it('should revert when IF cannot acquire', async function () {
      await expect(
        exchange.connect(dispatcherWallet).liquidatePositionBelowMinimum({
          baseAssetSymbol,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/initial margin requirement not met/i);
    });

    it('should revert when liquidating EF', async function () {
      await expect(
        exchange.connect(dispatcherWallet).liquidatePositionBelowMinimum({
          baseAssetSymbol,
          liquidatingWallet: exitFundWallet.address,
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/cannot liquidate EF/i);
    });

    it('should revert when liquidating IF', async function () {
      await expect(
        exchange.connect(dispatcherWallet).liquidatePositionBelowMinimum({
          baseAssetSymbol,
          liquidatingWallet: insuranceFundWallet.address,
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/cannot liquidate IF/i);
    });
  });

  describe('liquidatePositionInDeactivatedMarket', async function () {
    it('should work for valid long wallet position and market', async function () {
      await exchange
        .connect(dispatcherWallet)
        .deactivateMarket(baseAssetSymbol);

      await exchange
        .connect(dispatcherWallet)
        .liquidatePositionInDeactivatedMarket({
          baseAssetSymbol,
          feeQuantity: decimalToPips('20.00000000'),
          liquidatingWallet: trader2Wallet.address,
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        });
    });

    it('should work for valid short wallet position and market', async function () {
      await exchange
        .connect(dispatcherWallet)
        .deactivateMarket(baseAssetSymbol);

      await exchange
        .connect(dispatcherWallet)
        .liquidatePositionInDeactivatedMarket({
          baseAssetSymbol,
          feeQuantity: decimalToPips('20.00000000'),
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        });
    });

    it('should revert for invalid market', async function () {
      await expect(
        exchange
          .connect(dispatcherWallet)
          .liquidatePositionInDeactivatedMarket({
            baseAssetSymbol: 'XYZ',
            feeQuantity: decimalToPips('20.00000000'),
            liquidatingWallet: trader1Wallet.address,
            liquidationQuoteQuantity: decimalToPips('20000.00000000'),
          }),
      ).to.eventually.be.rejectedWith(/no inactive market found/i);
    });

    it('should when wallet has no open position', async function () {
      await exchange
        .connect(dispatcherWallet)
        .deactivateMarket(baseAssetSymbol);

      await exchange
        .connect(dispatcherWallet)
        .liquidatePositionInDeactivatedMarket({
          baseAssetSymbol,
          feeQuantity: decimalToPips('20.00000000'),
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        });

      await expect(
        exchange
          .connect(dispatcherWallet)
          .liquidatePositionInDeactivatedMarket({
            baseAssetSymbol,
            feeQuantity: decimalToPips('20.00000000'),
            liquidatingWallet: trader1Wallet.address,
            liquidationQuoteQuantity: decimalToPips('20000.00000000'),
          }),
      ).to.eventually.be.rejectedWith(/open position not found for market/i);
    });

    it('should revert when not sent by dispatcher', async function () {
      await expect(
        exchange.liquidatePositionInDeactivatedMarket({
          baseAssetSymbol,
          feeQuantity: decimalToPips('20.00000000'),
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantity: decimalToPips('20000.00000000'),
        }),
      ).to.eventually.be.rejectedWith(/caller must be dispatcher wallet/i);
    });

    it('should revert for invalid quote quantity', async function () {
      await (
        await exchange
          .connect(dispatcherWallet)
          .deactivateMarket(baseAssetSymbol)
      ).wait();

      await expect(
        exchange
          .connect(dispatcherWallet)
          .liquidatePositionInDeactivatedMarket({
            baseAssetSymbol,
            feeQuantity: decimalToPips('20.00000000'),
            liquidatingWallet: trader1Wallet.address,
            liquidationQuoteQuantity: decimalToPips('10000.00000000'),
          }),
      ).to.eventually.be.rejectedWith(/invalid quote quantity/i);
    });

    it('should revert for excessive fee', async function () {
      await (
        await exchange
          .connect(dispatcherWallet)
          .deactivateMarket(baseAssetSymbol)
      ).wait();

      await expect(
        exchange
          .connect(dispatcherWallet)
          .liquidatePositionInDeactivatedMarket({
            baseAssetSymbol,
            feeQuantity: decimalToPips('10000.00000000'),
            liquidatingWallet: trader1Wallet.address,
            liquidationQuoteQuantity: decimalToPips('20000.00000000'),
          }),
      ).to.eventually.be.rejectedWith(/excessive fee/i);
    });
  });

  describe('liquidateWalletInMaintenance', async function () {
    it('should work for valid wallet', async function () {
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

      await exchange.connect(dispatcherWallet).liquidateWalletInMaintenance({
        counterpartyWallet: insuranceFundWallet.address,
        liquidatingWallet: trader1Wallet.address,
        liquidationQuoteQuantities: ['21980.00000000'].map(decimalToPips),
      });
    });

    it('should work for valid wallet with one pip quote difference', async function () {
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

      await exchange.connect(dispatcherWallet).liquidateWalletInMaintenance({
        counterpartyWallet: insuranceFundWallet.address,
        liquidatingWallet: trader1Wallet.address,
        liquidationQuoteQuantities: ['21980.00000001'].map(decimalToPips),
      });
    });

    it('should revert when wallet is not in maintenance', async function () {
      await expect(
        exchange.connect(dispatcherWallet).liquidateWalletInMaintenance({
          counterpartyWallet: insuranceFundWallet.address,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantities: ['21980.00000000'].map(decimalToPips),
        }),
      ).to.eventually.be.rejectedWith(/maintenance margin requirement met/i);
    });

    it('should revert when counterparty is not IF', async function () {
      await expect(
        exchange.connect(dispatcherWallet).liquidateWalletInMaintenance({
          counterpartyWallet: trader2Wallet.address,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantities: ['21980.00000000'].map(decimalToPips),
        }),
      ).to.eventually.be.rejectedWith(/must liquidate to IF/i);
    });

    it('should revert for invalid quote quantity', async function () {
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

      await expect(
        exchange.connect(dispatcherWallet).liquidateWalletInMaintenance({
          counterpartyWallet: insuranceFundWallet.address,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantities: ['20080.00000000'].map(decimalToPips),
        }),
      ).to.eventually.be.rejectedWith(/invalid liquidation quote quantity/i);
    });

    it('should revert when not sent by dispatcher', async function () {
      await expect(
        exchange.liquidateWalletInMaintenance({
          counterpartyWallet: insuranceFundWallet.address,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantities: ['21980.00000000'].map(decimalToPips),
        }),
      ).to.eventually.be.rejectedWith(/caller must be dispatcher wallet/i);
    });

    it('should revert for deactivated market', async function () {
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

      await exchange
        .connect(dispatcherWallet)
        .deactivateMarket(baseAssetSymbol);

      await expect(
        exchange.connect(dispatcherWallet).liquidateWalletInMaintenance({
          counterpartyWallet: insuranceFundWallet.address,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantities: ['21980.00000000'].map(decimalToPips),
        }),
      ).to.eventually.be.rejectedWith(
        /cannot liquidate position in inactive market/i,
      );
    });
  });

  describe('liquidateWalletInMaintenanceDuringSystemRecovery', async function () {
    this.beforeEach(async () => {
      const newIndexPrice = await buildIndexPriceWithValue(
        indexPriceServiceWallet,
        '2150.00000000',
        baseAssetSymbol,
      );

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([indexPriceToArgumentStruct(newIndexPrice)]);

      await exchange.connect(trader2Wallet).exitWallet();
    });

    it('should work for valid wallet', async function () {
      await exchange.withdrawExit(trader2Wallet.address);

      await exchange
        .connect(dispatcherWallet)
        .liquidateWalletInMaintenanceDuringSystemRecovery({
          counterpartyWallet: exitFundWallet.address,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantities: ['21980.00000000'].map(decimalToPips),
        });
    });

    it('should revert when EF has no open balances', async function () {
      await expect(
        exchange
          .connect(dispatcherWallet)
          .liquidateWalletInMaintenanceDuringSystemRecovery({
            counterpartyWallet: exitFundWallet.address,
            liquidatingWallet: trader1Wallet.address,
            liquidationQuoteQuantities: ['21980.00000000'].map(decimalToPips),
          }),
      ).to.eventually.be.rejectedWith(/exit fund has no positions/i);
    });

    it('should revert when liquidating EF', async function () {
      await exchange.withdrawExit(trader2Wallet.address);

      await expect(
        exchange
          .connect(dispatcherWallet)
          .liquidateWalletInMaintenanceDuringSystemRecovery({
            counterpartyWallet: exitFundWallet.address,
            liquidatingWallet: exitFundWallet.address,
            liquidationQuoteQuantities: ['21980.00000000'].map(decimalToPips),
          }),
      ).to.eventually.be.rejectedWith(/cannot liquidate EF/i);
    });

    it('should revert when liquidating IF', async function () {
      await exchange.withdrawExit(trader2Wallet.address);

      await expect(
        exchange
          .connect(dispatcherWallet)
          .liquidateWalletInMaintenanceDuringSystemRecovery({
            counterpartyWallet: exitFundWallet.address,
            liquidatingWallet: insuranceFundWallet.address,
            liquidationQuoteQuantities: ['21980.00000000'].map(decimalToPips),
          }),
      ).to.eventually.be.rejectedWith(/cannot liquidate IF/i);
    });

    it('should revert when counterparty is not EF', async function () {
      await exchange.withdrawExit(trader2Wallet.address);

      await expect(
        exchange
          .connect(dispatcherWallet)
          .liquidateWalletInMaintenanceDuringSystemRecovery({
            counterpartyWallet: trader2Wallet.address,
            liquidatingWallet: trader1Wallet.address,
            liquidationQuoteQuantities: ['21980.00000000'].map(decimalToPips),
          }),
      ).to.eventually.be.rejectedWith(/must liquidate to EF/i);
    });
  });

  describe('liquidateWalletExit', async function () {
    it('should work for valid wallet', async function () {
      await fundWallets([insuranceFundWallet], exchange, usdc);

      await exchange.connect(trader1Wallet).exitWallet();

      await exchange.connect(dispatcherWallet).liquidateWalletExit({
        counterpartyWallet: insuranceFundWallet.address,
        liquidatingWallet: trader1Wallet.address,
        liquidationQuoteQuantities: ['20000.00000000'].map(decimalToPips),
      });
    });

    it('should work for valid wallet with negative EAV', async function () {
      await fundWallets(
        [insuranceFundWallet],
        exchange,
        usdc,
        '10000.00000000',
      );

      await exchange
        .connect(dispatcherWallet)
        .publishIndexPrices([
          indexPriceToArgumentStruct(
            await buildIndexPriceWithValue(
              indexPriceServiceWallet,
              '3000.00000000',
              baseAssetSymbol,
            ),
          ),
        ]);

      await exchange.connect(trader1Wallet).exitWallet();

      await exchange.connect(dispatcherWallet).liquidateWalletExit({
        counterpartyWallet: insuranceFundWallet.address,
        liquidatingWallet: trader1Wallet.address,
        liquidationQuoteQuantities: ['21980.00000000'].map(decimalToPips),
      });
    });

    it('should revert when not sent by dispatcher', async function () {
      await expect(
        exchange.liquidateWalletExit({
          counterpartyWallet: insuranceFundWallet.address,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantities: ['20000.00000000'].map(decimalToPips),
        }),
      ).to.eventually.be.rejectedWith(/caller must be dispatcher wallet/i);
    });

    it('should revert when counterparty is not IF', async function () {
      await exchange.connect(trader1Wallet).exitWallet();

      await expect(
        exchange.connect(dispatcherWallet).liquidateWalletExit({
          counterpartyWallet: exitFundWallet.address,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantities: ['21980.00000000'].map(decimalToPips),
        }),
      ).to.eventually.be.rejectedWith(/must liquidate to IF/i);
    });

    it('should revert when wallet not exited', async function () {
      await expect(
        exchange.connect(dispatcherWallet).liquidateWalletExit({
          counterpartyWallet: insuranceFundWallet.address,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantities: ['20000.00000000'].map(decimalToPips),
        }),
      ).to.eventually.be.rejectedWith(/wallet not exited/i);
    });

    it('should revert for inactive market', async function () {
      await exchange
        .connect(dispatcherWallet)
        .deactivateMarket(baseAssetSymbol);

      await exchange.connect(trader1Wallet).exitWallet();

      await expect(
        exchange.connect(dispatcherWallet).liquidateWalletExit({
          counterpartyWallet: insuranceFundWallet.address,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantities: ['20000.00000000'].map(decimalToPips),
        }),
      ).to.eventually.be.rejectedWith(
        /cannot liquidate position in inactive market/i,
      );
    });

    it('should revert on invalid quote quantity', async function () {
      await exchange.connect(trader1Wallet).exitWallet();

      await expect(
        exchange.connect(dispatcherWallet).liquidateWalletExit({
          counterpartyWallet: insuranceFundWallet.address,
          liquidatingWallet: trader1Wallet.address,
          liquidationQuoteQuantities: ['21500.00000000'].map(decimalToPips),
        }),
      ).to.eventually.be.rejectedWith(/invalid exit quote quantity/i);
    });
  });
});
