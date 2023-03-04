import { ethers } from 'hardhat';
import { IndexPrice } from '../lib';

import type { ChainlinkAggregatorMock, Exchange_v4 } from '../typechain-types';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import {
  buildIndexPrice,
  deployAndAssociateContracts,
  executeTrade,
  expect,
  fundWallets,
} from './helpers';

describe('Exchange', function () {
  let chainlinkAggregator: ChainlinkAggregatorMock;
  let exchange: Exchange_v4;
  let exitFundWallet: SignerWithAddress;
  let indexPrice: IndexPrice;
  let indexPriceServiceWallet: SignerWithAddress;
  let insuranceFundWallet: SignerWithAddress;
  let ownerWallet: SignerWithAddress;
  let dispatcherWallet: SignerWithAddress;
  let trader1Wallet: SignerWithAddress;
  let trader2Wallet: SignerWithAddress;

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
    chainlinkAggregator = results.chainlinkAggregator;

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

  describe('index price margin', () => {
    describe('loadTotalAccountValueFromIndexPrices', () => {
      it('should work for wallet with open position', async () => {
        const totalAccountValue =
          await exchange.loadTotalAccountValueFromIndexPrices(
            trader1Wallet.address,
          );
        // TODO value assertions
      });

      describe('loadTotalInitialMarginRequirementFromIndexPrices', () => {
        it('should work for wallet with open position', async () => {
          const totalInitialMarginRequirement =
            await exchange.loadTotalInitialMarginRequirementFromIndexPrices(
              trader1Wallet.address,
            );
          // TODO value assertions
        });
      });

      describe('loadTotalMaintenanceMarginRequirementFromIndexPrices', () => {
        it('should work for wallet with open position', async () => {
          const totalMaintenanceMarginRequirement =
            await exchange.loadTotalMaintenanceMarginRequirementFromIndexPrices(
              trader1Wallet.address,
            );
          // TODO value assertions
        });
      });
    });
  });

  describe('oracle price margin', () => {
    describe('ChainlinkAggregatorMock', () => {
      it('should implement AggregatorV3Interface', async () => {
        await expect(chainlinkAggregator.decimals()).to.eventually.be.a(
          'number',
        );
        await expect(chainlinkAggregator.description()).to.eventually.be.a(
          'string',
        );
        await expect(chainlinkAggregator.getRoundData(0)).to.eventually.be.an(
          'array',
        );
        await expect(chainlinkAggregator.version()).to.eventually.be.an(
          'Object',
        );
      });

      it('setPrice should validate input', async () => {
        await expect(
          chainlinkAggregator.setPrice(0),
        ).to.eventually.be.rejectedWith(/price cannot be zero/i);

        await expect(
          chainlinkAggregator.setPrice((BigInt(2) ** BigInt(128)).toString()),
        ).to.eventually.be.rejectedWith(/price overflows uint64/i);
      });
    });

    describe('loadTotalAccountValueFromOraclePrices', () => {
      it('should work for wallet with open position', async () => {
        const totalAccountValue =
          await exchange.loadTotalAccountValueFromOraclePrices(
            trader1Wallet.address,
          );
        // TODO value assertions
      });
    });

    describe('loadTotalInitialMarginRequirementFromOraclePrices', () => {
      it('should work for wallet with open position', async () => {
        const totalInitialMarginRequirement =
          await exchange.loadTotalInitialMarginRequirementFromOraclePrices(
            trader1Wallet.address,
          );
        // TODO value assertions
      });
    });

    describe('loadTotalMaintenanceMarginRequirementFromOraclePrices', () => {
      it('should work for wallet with open position', async () => {
        const totalMaintenanceMarginRequirement =
          await exchange.loadTotalMaintenanceMarginRequirementFromOraclePrices(
            trader1Wallet.address,
          );
        // TODO value assertions
      });
    });
  });
});
