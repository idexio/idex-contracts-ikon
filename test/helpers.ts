import BigNumber from 'bignumber.js';
import { ethers } from 'hardhat';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { v1 as uuidv1 } from 'uuid';
import type { BigNumber as EthersBigNumber, Contract } from 'ethers';

import {
  decimalToAssetUnits,
  decimalToPips,
  fundingPeriodLengthInMs,
  getIndexPriceHash,
  getOrderHash,
  indexPriceToArgumentStruct,
  IndexPrice,
  Order,
  OrderSide,
  OrderType,
  pipsDecimals,
  signatureHashVersion,
} from '../lib';
import { Exchange_v4, USDC } from '../typechain-types';

export const quoteAssetDecimals = 6;

export const baseAssetSymbol = 'ETH';

export const quoteAssetSymbol = 'USDC';

export async function buildIndexPrice(
  index: SignerWithAddress,
): Promise<IndexPrice> {
  return (await buildIndexPrices(index, 1))[0];
}

const prices = [
  '2000.00000000',
  '2100.00000000',
  '1950.00000000',
  '1996.79000000',
  '1724.64000000',
];
export async function buildIndexPrices(
  index: SignerWithAddress,
  count = 1,
): Promise<IndexPrice[]> {
  return Promise.all(
    Array(count)
      .fill(null)
      .map(async (_, i) => {
        const indexPrice = {
          baseAssetSymbol,
          timestampInMs: getPastPeriodInMs(count - i),
          price: prices[i % prices.length],
        };
        const signature = await index.signMessage(
          ethers.utils.arrayify(
            getIndexPriceHash(indexPrice, quoteAssetSymbol),
          ),
        );

        return { ...indexPrice, signature };
      }),
  );
}

export async function buildIndexPriceWithValue(
  index: SignerWithAddress,
  price: string,
  baseAssetSymbol_ = baseAssetSymbol,
): Promise<IndexPrice> {
  const indexPrice = {
    baseAssetSymbol: baseAssetSymbol_,
    timestampInMs: new Date().getTime(),
    price,
  };
  const signature = await index.signMessage(
    ethers.utils.arrayify(getIndexPriceHash(indexPrice, quoteAssetSymbol)),
  );

  return { ...indexPrice, signature };
}

export async function buildLimitOrder(
  signer: SignerWithAddress,
  side: OrderSide,
  market = `${baseAssetSymbol}-USDC`,
  quantity = '1.00000000',
  price = '2000.00000000',
) {
  const order: Order = {
    signatureHashVersion,
    nonce: uuidv1(),
    wallet: signer.address,
    market,
    type: OrderType.Limit,
    side,
    quantity,
    price,
  };
  const signature = await signer.signMessage(
    ethers.utils.arrayify(getOrderHash(order)),
  );

  return { order, signature };
}

const fundingRates = ['-16100', '26400', '-28200', '-5000', '10400'];
export function buildFundingRates(count = 1): string[] {
  return Array(count)
    .fill(null)
    .map((_, i) => fundingRates[i % 5]);
}

export async function deployAndAssociateContracts(
  owner: SignerWithAddress,
  dispatcher: SignerWithAddress = owner,
  exitFundWallet: SignerWithAddress = owner,
  feeWallet: SignerWithAddress = owner,
  insuranceFund: SignerWithAddress = owner,
  indexPriceCollectionServiceWallet: SignerWithAddress = owner,
) {
  const [
    AcquisitionDeleveraging,
    ClosureDeleveraging,
    Depositing,
    Funding,
    MarketAdmin,
    NonceInvalidations,
    NonMutatingMargin,
    PositionBelowMinimumLiquidation,
    PositionInDeactivatedMarketLiquidation,
    Trading,
    WalletLiquidation,
    Withdrawing,
  ] = await Promise.all([
    ethers.getContractFactory('AcquisitionDeleveraging'),
    ethers.getContractFactory('ClosureDeleveraging'),
    ethers.getContractFactory('Depositing'),
    ethers.getContractFactory('Funding'),
    ethers.getContractFactory('MarketAdmin'),
    ethers.getContractFactory('NonceInvalidations'),
    ethers.getContractFactory('NonMutatingMargin'),
    ethers.getContractFactory('PositionBelowMinimumLiquidation'),
    ethers.getContractFactory('PositionInDeactivatedMarketLiquidation'),
    ethers.getContractFactory('Trading'),
    ethers.getContractFactory('WalletLiquidation'),
    ethers.getContractFactory('Withdrawing'),
  ]);
  const [
    acquisitionDeleveraging,
    closureDeleveraging,
    depositing,
    funding,
    marketAdmin,
    nonceInvalidations,
    nonMutatingMargin,
    positionBelowMinimumLiquidation,
    positionInDeactivatedMarketLiquidation,
    trading,
    walletLiquidation,
    withdrawing,
  ] = await Promise.all([
    (await AcquisitionDeleveraging.deploy()).deployed(),
    (await ClosureDeleveraging.deploy()).deployed(),
    (await Depositing.deploy()).deployed(),
    (await Funding.deploy()).deployed(),
    (await MarketAdmin.deploy()).deployed(),
    (await NonceInvalidations.deploy()).deployed(),
    (await NonMutatingMargin.deploy()).deployed(),
    (await PositionBelowMinimumLiquidation.deploy()).deployed(),
    (await PositionInDeactivatedMarketLiquidation.deploy()).deployed(),
    (await Trading.deploy()).deployed(),
    (await WalletLiquidation.deploy()).deployed(),
    (await Withdrawing.deploy()).deployed(),
  ]);

  const [ChainlinkAggregator, USDC, Exchange_v4, Governance, Custodian] =
    await Promise.all([
      ethers.getContractFactory('ChainlinkAggregator'),
      ethers.getContractFactory('USDC'),
      ethers.getContractFactory('Exchange_v4', {
        libraries: {
          AcquisitionDeleveraging: acquisitionDeleveraging.address,
          ClosureDeleveraging: closureDeleveraging.address,
          Depositing: depositing.address,
          Funding: funding.address,
          MarketAdmin: marketAdmin.address,
          NonceInvalidations: nonceInvalidations.address,
          NonMutatingMargin: nonMutatingMargin.address,
          PositionBelowMinimumLiquidation:
            positionBelowMinimumLiquidation.address,
          PositionInDeactivatedMarketLiquidation:
            positionInDeactivatedMarketLiquidation.address,
          Trading: trading.address,
          WalletLiquidation: walletLiquidation.address,
          Withdrawing: withdrawing.address,
        },
      }),
      ethers.getContractFactory('Governance'),
      ethers.getContractFactory('Custodian'),
    ]);

  const chainlinkAggregator = await (
    await ChainlinkAggregator.deploy()
  ).deployed();

  (await chainlinkAggregator.setPrice(decimalToPips('2000.00000000'))).wait();

  const usdc = await (await USDC.deploy()).deployed();

  const [exchange, governance] = await Promise.all([
    (
      await Exchange_v4.deploy(
        ethers.constants.AddressZero,
        usdc.address,
        exitFundWallet.address,
        feeWallet.address,
        insuranceFund.address,
        [indexPriceCollectionServiceWallet.address],
      )
    ).deployed(),
    (await Governance.deploy(0)).deployed(),
  ]);

  const custodian = await (
    await Custodian.deploy(exchange.address, governance.address)
  ).deployed();

  await Promise.all([
    (await exchange.setCustodian(custodian.address)).wait(),
    (await exchange.setDepositIndex()).wait(),
    (await exchange.setDispatcher(dispatcher.address)).wait(),
    (await governance.setCustodian(custodian.address)).wait(),
    (
      await exchange.addMarket({
        exists: true,
        isActive: false,
        baseAssetSymbol,
        chainlinkPriceFeedAddress: chainlinkAggregator.address,
        lastIndexPriceTimestampInMs: 0,
        indexPriceAtDeactivation: 0,
        overridableFields: {
          initialMarginFraction: '5000000',
          maintenanceMarginFraction: '3000000',
          incrementalInitialMarginFraction: '1000000',
          baselinePositionSize: '14000000000',
          incrementalPositionSize: '2800000000',
          maximumPositionSize: '282000000000',
          minimumPositionSize: '2000000000',
        },
      })
    ).wait(),
  ]);
  (await exchange.connect(dispatcher).activateMarket(baseAssetSymbol)).wait();

  return { chainlinkAggregator, usdc, custodian, exchange, governance };
}

export async function fundWallets(
  wallets: SignerWithAddress[],
  exchange: Exchange_v4,
  usdc: USDC,
  quantity = '2000.00000000',
) {
  await Promise.all(
    wallets.map(async (wallet) =>
      (
        await usdc.transfer(
          wallet.address,
          decimalToAssetUnits(quantity, quoteAssetDecimals),
        )
      ).wait(),
    ),
  );

  await Promise.all(
    wallets.map(async (wallet) =>
      (
        await usdc
          .connect(wallet)
          .approve(
            exchange.address,
            decimalToAssetUnits(quantity, quoteAssetDecimals),
          )
      ).wait(),
    ),
  );

  await Promise.all(
    wallets.map(async (wallet) =>
      (
        await exchange
          .connect(wallet)
          .deposit(decimalToAssetUnits(quantity, quoteAssetDecimals))
      ).wait(),
    ),
  );
}

function getPastPeriodInMs(periodsAgo = 0) {
  return new Date(
    Math.round(
      (new Date().getTime() - periodsAgo * fundingPeriodLengthInMs) /
        fundingPeriodLengthInMs,
    ) * fundingPeriodLengthInMs,
  ).getTime();
}

export async function loadFundingMultipliers(
  exchange: Exchange_v4,
  baseAssetSymbol_ = baseAssetSymbol,
) {
  const multipliers: string[][] = [];
  try {
    let i = 0;
    while (true) {
      multipliers.push(
        (
          await exchange.fundingMultipliersByBaseAssetSymbol(
            baseAssetSymbol_,
            i,
          )
        ).map((m) => m.toString()),
      );

      i += 1;
    }
  } catch (e) {
    if (e instanceof Error && !e.message.match(/^call revert exception/)) {
      console.error(e.message);
    }
  }

  return multipliers;
}

export async function logWalletBalances(
  wallet: string,
  exchange: Contract,
  indexPrices: IndexPrice[],
) {
  console.log(
    `USDC balance: ${pipToDecimal(
      await exchange.loadBalanceBySymbol(wallet, 'USDC'),
    )}`,
  );

  for (const indexPrice of indexPrices) {
    console.log(
      `${indexPrice.baseAssetSymbol} balance:  ${pipToDecimal(
        await exchange.loadBalanceBySymbol(wallet, indexPrice.baseAssetSymbol),
      )}`,
    );
    console.log(
      `${indexPrice.baseAssetSymbol} cost basis: ${pipToDecimal(
        (
          await exchange.loadBalanceStructBySymbol(
            wallet,
            indexPrice.baseAssetSymbol,
          )
        ).costBasis,
      )}`,
    );
  }

  console.log(
    `Total account value: ${pipToDecimal(
      await exchange.loadTotalAccountValue(
        wallet,
        indexPrices.map(indexPriceToArgumentStruct),
      ),
    )}`,
  );
  console.log(
    `Outstanding funding payments: ${pipToDecimal(
      await exchange.loadOutstandingWalletFunding(wallet),
    )}`,
  );
  console.log(
    `Initial margin requirement: ${pipToDecimal(
      await exchange.loadTotalInitialMarginRequirement(
        wallet,
        indexPrices.map(indexPriceToArgumentStruct),
      ),
    )}`,
  );
  console.log(
    `Maintenance margin requirement: ${pipToDecimal(
      await exchange.loadTotalMaintenanceMarginRequirement(
        wallet,
        indexPrices.map(indexPriceToArgumentStruct),
      ),
    )}`,
  );
}

/**
 * Returns the given number of pips as a floating point number with 8 decimals.
 * Examples:
 * BigInt(12345678) => '0.12345678'
 * BigInt(123456789) => '1.23456789'
 * BigInt(100000000) => '1.00000000'
 * BigInt(120000000) => '1.20000000'
 * BigInt(1) => '0.00000001'
 */
export const pipToDecimal = function pipToDecimal(
  pips: EthersBigNumber,
): string {
  const bn = new BigNumber(pips.toString());
  return bn.shiftedBy(pipsDecimals * -1).toFixed(pipsDecimals);
};
