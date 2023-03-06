import { ethers } from 'hardhat';
import { expect } from 'chai';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

import type { Exchange_v4 } from '../typechain-types';
import type { MarketStruct } from '../typechain-types/contracts/Exchange.sol/Exchange_v4';
import {
  baseAssetSymbol,
  buildIndexPrice,
  deployAndAssociateContracts,
} from './helpers';
import { indexPriceToArgumentStruct } from '../lib';

describe('Exchange', function () {
  let exchange: Exchange_v4;
  let indexPriceServiceWallet: SignerWithAddress;
  let marketStruct: MarketStruct;
  let ownerWallet: SignerWithAddress;

  beforeEach(async () => {
    [ownerWallet] = await ethers.getSigners();
    const results = await deployAndAssociateContracts(ownerWallet);
    exchange = results.exchange;
    indexPriceServiceWallet = ownerWallet;
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

    it('should revert for invalid chainlink aggregator address', async () => {
      marketStruct.baseAssetSymbol = 'XYZ';
      marketStruct.chainlinkPriceFeedAddress = ownerWallet.address;
      await expect(
        exchange.addMarket(marketStruct),
      ).to.eventually.be.rejectedWith(/invalid Chainlink price feed/i);
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
      const indexPrice = await buildIndexPrice(indexPriceServiceWallet);
      await expect(
        exchange
          .connect((await ethers.getSigners())[1])
          .publishIndexPrices([indexPriceToArgumentStruct(indexPrice)]),
      ).to.eventually.be.rejectedWith(/caller must be dispatcher wallet/i);
    });

    it('should revert when market not found', async () => {
      const indexPrice = await buildIndexPrice(indexPriceServiceWallet, 'XYZ');

      await expect(
        exchange.publishIndexPrices([indexPriceToArgumentStruct(indexPrice)]),
      ).to.eventually.be.rejectedWith(/active market not found/i);
    });

    it('should revert when index price is outdated', async () => {
      const indexPrice = await buildIndexPrice(indexPriceServiceWallet);
      indexPrice.timestampInMs -= 2 * 24 * 60 * 60 * 1000;

      await expect(
        exchange.publishIndexPrices([indexPriceToArgumentStruct(indexPrice)]),
      ).to.eventually.be.rejectedWith(/outdated index price/i);
    });

    it('should revert when index price is too far in future', async () => {
      const indexPrice = await buildIndexPrice(indexPriceServiceWallet);
      indexPrice.timestampInMs += 2 * 24 * 60 * 60 * 1000;

      await expect(
        exchange.publishIndexPrices([indexPriceToArgumentStruct(indexPrice)]),
      ).to.eventually.be.rejectedWith(/index price timestamp too high/i);
    });

    it('should revert when IPS signature hash version is invalid', async () => {
      const indexPrice = await buildIndexPrice(indexPriceServiceWallet);
      indexPrice.signatureHashVersion = 111;

      await expect(
        exchange.publishIndexPrices([indexPriceToArgumentStruct(indexPrice)]),
      ).to.eventually.be.rejectedWith(/signature hash version invalid/i);
    });

    it('should revert when IPS signature is invalid', async () => {
      const indexPrice = await buildIndexPrice(indexPriceServiceWallet);
      indexPrice.timestampInMs += 5;

      await expect(
        exchange.publishIndexPrices([indexPriceToArgumentStruct(indexPrice)]),
      ).to.eventually.be.rejectedWith(/invalid index price signature/i);
    });
  });
});
