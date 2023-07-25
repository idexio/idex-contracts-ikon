import BigNumber from 'bignumber.js';
import { expect } from 'chai';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { ethers, network } from 'hardhat';

import type {
  Exchange_v4,
  IDEXIndexAndOraclePriceAdapter,
} from '../typechain-types';
import type { MarketStruct } from '../typechain-types/contracts/Exchange.sol/Exchange_v4';
import {
  baseAssetSymbol,
  buildIndexPrice,
  buildIndexPriceWithTimestamp,
  deployAndAssociateContracts,
  getLatestBlockTimestampInSeconds,
  quoteAssetSymbol,
} from './helpers';
import { indexPriceToArgumentStruct } from '../lib';

describe('Exchange', function () {
  let exchange: Exchange_v4;
  let indexPriceAdapter: IDEXIndexAndOraclePriceAdapter;
  let indexPriceServiceWallet: SignerWithAddress;
  let marketStruct: MarketStruct;
  let ownerWallet: SignerWithAddress;

  before(async () => {
    await network.provider.send('hardhat_reset');
  });

  beforeEach(async () => {
    [ownerWallet] = await ethers.getSigners();
    const results = await deployAndAssociateContracts(ownerWallet);
    exchange = results.exchange;
    indexPriceAdapter = results.indexPriceAdapter;
    indexPriceServiceWallet = ownerWallet;
    marketStruct = {
      exists: true,
      isActive: false,
      baseAssetSymbol,
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
  });

  describe('activateMarket', async function () {
    it('should revert when not called by dispatcher wallet', async () => {
      await expect(
        exchange
          .connect((await ethers.getSigners())[1])
          .activateMarket(marketStruct.baseAssetSymbol),
      ).to.eventually.be.rejectedWith(/caller must be dispatcher wallet/i);
    });

    it('should revert when market already active', async () => {
      await expect(
        exchange.activateMarket(marketStruct.baseAssetSymbol),
      ).to.eventually.be.rejectedWith(/no inactive market found/i);
    });
  });

  describe('addMarket', async function () {
    it('should revert when not called by admin', async () => {
      await expect(
        exchange
          .connect((await ethers.getSigners())[1])
          .addMarket(marketStruct),
      ).to.eventually.be.rejectedWith(/caller must be admin wallet/i);
    });

    it('should revert for existing base asset symbol', async () => {
      await expect(
        exchange.addMarket(marketStruct),
      ).to.eventually.be.rejectedWith(/market already exists/i);
    });

    it('should revert when using quote asset symbol as base asset symbol', async () => {
      await expect(
        exchange.addMarket({
          ...marketStruct,
          baseAssetSymbol: quoteAssetSymbol,
        }),
      ).to.eventually.be.rejectedWith(
        /base asset symbol cannot be same as quote/i,
      );
    });

    it('should revert for invalid initial margin fraction', async () => {
      marketStruct.baseAssetSymbol = 'XYZ';
      marketStruct.overridableFields.initialMarginFraction = '1';
      await expect(
        exchange.addMarket(marketStruct),
      ).to.eventually.be.rejectedWith(/initial margin fraction below min/i);
    });

    it('should revert for invalid maintenance margin fraction', async () => {
      marketStruct.baseAssetSymbol = 'XYZ';
      marketStruct.overridableFields.maintenanceMarginFraction = '1';
      await expect(
        exchange.addMarket(marketStruct),
      ).to.eventually.be.rejectedWith(/maintenance margin fraction below min/i);
    });

    it('should revert for invalid incremental initial margin fraction', async () => {
      marketStruct.baseAssetSymbol = 'XYZ';
      marketStruct.overridableFields.incrementalInitialMarginFraction = '1';
      await expect(
        exchange.addMarket(marketStruct),
      ).to.eventually.be.rejectedWith(
        /incremental initial margin fraction below min/i,
      );
    });

    it('should revert for invalid incremental position size', async () => {
      marketStruct.baseAssetSymbol = 'XYZ';
      marketStruct.overridableFields.incrementalPositionSize = '0';
      await expect(
        exchange.addMarket(marketStruct),
      ).to.eventually.be.rejectedWith(
        /incremental position size cannot be zero/i,
      );
    });

    it('should revert for invalid baseline position size', async () => {
      marketStruct.baseAssetSymbol = 'XYZ';
      marketStruct.overridableFields.baselinePositionSize = new BigNumber(2)
        .pow(63)
        .toString();
      await expect(
        exchange.addMarket(marketStruct),
      ).to.eventually.be.rejectedWith(/baseline position size exceeds max/i);
    });

    it('should revert for invalid maximum position size', async () => {
      marketStruct.baseAssetSymbol = 'XYZ';
      marketStruct.overridableFields.maximumPositionSize = new BigNumber(2)
        .pow(63)
        .toString();
      await expect(
        exchange.addMarket(marketStruct),
      ).to.eventually.be.rejectedWith(/maximum position size exceeds max/i);
    });

    it('should revert for invalid minimum position size', async () => {
      marketStruct.baseAssetSymbol = 'XYZ';
      marketStruct.overridableFields.minimumPositionSize = new BigNumber(2)
        .pow(63)
        .minus(1)
        .toString();
      await expect(
        exchange.addMarket(marketStruct),
      ).to.eventually.be.rejectedWith(/minimum position size exceeds max/i);
    });
  });

  describe('deactivateMarket', async function () {
    it('should revert when not called by dispatcher', async () => {
      await expect(
        exchange
          .connect((await ethers.getSigners())[1])
          .deactivateMarket(baseAssetSymbol),
      ).to.eventually.be.rejectedWith(/caller must be dispatcher wallet/i);
    });

    it('should revert when market does not exist', async () => {
      await expect(
        exchange.deactivateMarket('XYZ'),
      ).to.eventually.be.rejectedWith(/no active market found/i);
    });
  });

  describe('publishIndexPrices', async function () {
    it('should revert when not called by dispatcher', async () => {
      const indexPrice = await buildIndexPrice(
        exchange.address,
        indexPriceServiceWallet,
      );
      await expect(
        exchange
          .connect((await ethers.getSigners())[1])
          .publishIndexPrices([
            indexPriceToArgumentStruct(indexPriceAdapter.address, indexPrice),
          ]),
      ).to.eventually.be.rejectedWith(/caller must be dispatcher wallet/i);
    });

    it('should revert when market not found', async () => {
      const indexPrice = await buildIndexPrice(
        exchange.address,
        indexPriceServiceWallet,
        'XYZ',
      );

      await expect(
        exchange.publishIndexPrices([
          indexPriceToArgumentStruct(indexPriceAdapter.address, indexPrice),
        ]),
      ).to.eventually.be.rejectedWith(/active market not found/i);
    });

    it('should revert when index price is outdated', async () => {
      const indexPrice = await buildIndexPriceWithTimestamp(
        exchange.address,
        indexPriceServiceWallet,
        (await getLatestBlockTimestampInSeconds()) * 1000 -
          2 * 24 * 60 * 60 * 1000,
      );

      await expect(
        exchange.publishIndexPrices([
          indexPriceToArgumentStruct(indexPriceAdapter.address, indexPrice),
        ]),
      ).to.eventually.be.rejectedWith(/outdated index price/i);
    });

    it('should revert when index price is too far in future', async () => {
      const indexPrice = await buildIndexPriceWithTimestamp(
        exchange.address,
        indexPriceServiceWallet,
        (await getLatestBlockTimestampInSeconds()) * 1000 +
          2 * 24 * 60 * 60 * 1000,
      );

      await expect(
        exchange.publishIndexPrices([
          indexPriceToArgumentStruct(indexPriceAdapter.address, indexPrice),
        ]),
      ).to.eventually.be.rejectedWith(/index price timestamp too high/i);
    });

    it('should revert when index price adapter is not whitelisted', async () => {
      const indexPrice = await buildIndexPrice(
        exchange.address,
        indexPriceServiceWallet,
      );
      indexPrice.timestampInMs += 5;

      await expect(
        exchange.publishIndexPrices([
          indexPriceToArgumentStruct(exchange.address, indexPrice),
        ]),
      ).to.eventually.be.rejectedWith(/invalid index price adapter/i);
    });

    it('should revert when IPS signature is invalid', async () => {
      const indexPrice = await buildIndexPrice(
        exchange.address,
        indexPriceServiceWallet,
      );
      indexPrice.timestampInMs += 5;

      await expect(
        exchange.publishIndexPrices([
          indexPriceToArgumentStruct(indexPriceAdapter.address, indexPrice),
        ]),
      ).to.eventually.be.rejectedWith(/invalid index price signature/i);
    });
  });
});
