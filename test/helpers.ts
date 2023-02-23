import BigNumber from 'bignumber.js';
import chai from 'chai';
import chaiAsPromised from 'chai-as-promised';
import { ethers } from 'hardhat';
import { mine } from '@nomicfoundation/hardhat-network-helpers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { v1 as uuidv1 } from 'uuid';
import type { BigNumber as EthersBigNumber, Contract } from 'ethers';

chai.use(chaiAsPromised);
export const { expect } = chai;

import {
  decimalToAssetUnits,
  decimalToPips,
  fundingPeriodLengthInMs,
  getExecuteOrderBookTradeArguments,
  getIndexPriceHash,
  getOrderHash,
  indexPriceToArgumentStruct,
  IndexPrice,
  Order,
  OrderSide,
  OrderType,
  pipsDecimals,
  signatureHashVersion,
  Trade,
} from '../lib';
import { Exchange_v4, USDC } from '../typechain-types';

export const quoteAssetDecimals = 6;

export const baseAssetSymbol = 'ETH';

export const quoteAssetSymbol = 'USDC';

export async function bootstrapLiquidatedWallet() {
  const [
    ownerWallet,
    dispatcherWallet,
    exitFundWallet,
    feeWallet,
    insuranceWallet,
    indexPriceServiceWallet,
    trader1Wallet,
    trader2Wallet,
  ] = await ethers.getSigners();
  const { exchange, usdc } = await deployAndAssociateContracts(
    ownerWallet,
    dispatcherWallet,
    exitFundWallet,
    feeWallet,
    insuranceWallet,
    indexPriceServiceWallet,
  );

  await usdc.connect(dispatcherWallet).faucet(dispatcherWallet.address);

  await fundWallets(
    [trader1Wallet, trader2Wallet, insuranceWallet],
    exchange,
    usdc,
  );

  const indexPrice = await buildIndexPrice(indexPriceServiceWallet);

  await executeTrade(
    exchange,
    dispatcherWallet,
    indexPrice,
    trader1Wallet,
    trader2Wallet,
  );

  const liquidationIndexPrice = await buildIndexPriceWithValue(
    indexPriceServiceWallet,
    '2150.00000000',
    baseAssetSymbol,
    2,
  );

  await exchange
    .connect(dispatcherWallet)
    .publishIndexPrices([indexPriceToArgumentStruct(liquidationIndexPrice)]);

  await exchange.connect(dispatcherWallet).liquidateWalletInMaintenance({
    counterpartyWallet: insuranceWallet.address,
    liquidatingWallet: trader1Wallet.address,
    liquidationQuoteQuantities: ['21980.00000000'].map(decimalToPips),
  });

  return {
    dispatcherWallet,
    exchange,
    insuranceWallet,
    liquidationIndexPrice,
    liquidatedWallet: trader1Wallet,
    counterpartyWallet: trader2Wallet,
  };
}

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
          signatureHashVersion,
          baseAssetSymbol,
          timestampInMs: getNextPeriodInMs(i + 1),
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
  indexPriceServiceWallet: SignerWithAddress,
  price: string,
  baseAssetSymbol_ = baseAssetSymbol,
  periodsInFuture = 1,
): Promise<IndexPrice> {
  const indexPrice = {
    signatureHashVersion,
    baseAssetSymbol: baseAssetSymbol_,
    timestampInMs: getNextPeriodInMs(periodsInFuture),
    price,
  };
  const signature = await indexPriceServiceWallet.signMessage(
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

const fundingRates = [
  '-0.00016100',
  '0.00026400',
  '-0.00028200',
  '-0.00005000',
  '0.00010400',
];
export function buildFundingRates(count = 1): string[] {
  return Array(count)
    .fill(null)
    .map((_, i) => fundingRates[i % 5]);
}

export async function deployContractsExceptCustodian(
  owner: SignerWithAddress,
  exitFundWallet: SignerWithAddress = owner,
  feeWallet: SignerWithAddress = owner,
  indexPriceServiceWallet: SignerWithAddress = owner,
  insuranceFund: SignerWithAddress = owner,
  governanceBlockDelay = 0,
) {
  const [
    ChainlinkAggregatorFactory,
    USDCFactory,
    ExchangeFactory,
    GovernanceFactory,
  ] = await Promise.all([
    ethers.getContractFactory('ChainlinkAggregatorMock'),
    ethers.getContractFactory('USDC'),
    deployLibraryContracts(),
    ethers.getContractFactory('Governance'),
  ]);

  const chainlinkAggregator = await (
    await ChainlinkAggregatorFactory.connect(owner).deploy()
  ).deployed();

  (await chainlinkAggregator.setPrice(decimalToPips('2000.00000000'))).wait();

  const usdc = await (await USDCFactory.connect(owner).deploy()).deployed();

  const [exchange, governance] = await Promise.all([
    (
      await ExchangeFactory.connect(owner).deploy({
        balanceMigrationSource: ethers.constants.AddressZero,
        exitFundWallet: exitFundWallet.address,
        feeWallet: feeWallet.address,
        indexPriceServiceWallets: [indexPriceServiceWallet.address],
        insuranceFundWallet: insuranceFund.address,
        quoteAssetAddress: usdc.address,
      })
    ).deployed(),
    (
      await GovernanceFactory.connect(owner).deploy(governanceBlockDelay)
    ).deployed(),
  ]);

  return { chainlinkAggregator, exchange, ExchangeFactory, governance, usdc };
}

export async function deployAndAssociateContracts(
  owner: SignerWithAddress,
  dispatcher: SignerWithAddress = owner,
  exitFundWallet: SignerWithAddress = owner,
  feeWallet: SignerWithAddress = owner,
  insuranceFund: SignerWithAddress = owner,
  indexPriceServiceWallet: SignerWithAddress = owner,
  governanceBlockDelay = 0,
) {
  const { chainlinkAggregator, exchange, ExchangeFactory, governance, usdc } =
    await deployContractsExceptCustodian(
      owner,
      exitFundWallet,
      feeWallet,
      indexPriceServiceWallet,
      insuranceFund,
      governanceBlockDelay,
    );

  const Custodian = await ethers.getContractFactory('Custodian');
  const custodian = await (
    await Custodian.deploy(exchange.address, governance.address)
  ).deployed();

  await Promise.all([
    (await exchange.setCustodian(custodian.address, [])).wait(),
    (await exchange.setDepositIndex()).wait(),
    (await exchange.setDispatcher(dispatcher.address)).wait(),
    (await governance.setCustodian(custodian.address)).wait(),
    (
      await exchange.addMarket({
        exists: true,
        isActive: false,
        baseAssetSymbol,
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
      })
    ).wait(),
  ]);
  (await exchange.connect(dispatcher).activateMarket(baseAssetSymbol)).wait();

  return {
    chainlinkAggregator,
    custodian,
    exchange,
    ExchangeFactory,
    governance,
    usdc,
  };
}

export async function deployLibraryContracts() {
  const [
    AcquisitionDeleveraging,
    ClosureDeleveraging,
    Depositing,
    Funding,
    IndexPriceMargin,
    MarketAdmin,
    NonceInvalidations,
    OraclePriceMargin,
    PositionBelowMinimumLiquidation,
    PositionInDeactivatedMarketLiquidation,
    Trading,
    Transferring,
    WalletLiquidation,
    Withdrawing,
  ] = await Promise.all([
    ethers.getContractFactory('AcquisitionDeleveraging'),
    ethers.getContractFactory('ClosureDeleveraging'),
    ethers.getContractFactory('Depositing'),
    ethers.getContractFactory('Funding'),
    ethers.getContractFactory('IndexPriceMargin'),
    ethers.getContractFactory('MarketAdmin'),
    ethers.getContractFactory('NonceInvalidations'),
    ethers.getContractFactory('OraclePriceMargin'),
    ethers.getContractFactory('PositionBelowMinimumLiquidation'),
    ethers.getContractFactory('PositionInDeactivatedMarketLiquidation'),
    ethers.getContractFactory('Trading'),
    ethers.getContractFactory('Transferring'),
    ethers.getContractFactory('WalletLiquidation'),
    ethers.getContractFactory('Withdrawing'),
  ]);

  const [
    acquisitionDeleveraging,
    closureDeleveraging,
    depositing,
    funding,
    indexPriceMargin,
    marketAdmin,
    nonceInvalidations,
    onChainPriceFeedMargin,
    positionBelowMinimumLiquidation,
    positionInDeactivatedMarketLiquidation,
    trading,
    transferring,
    walletLiquidation,
    withdrawing,
  ] = await Promise.all([
    (await AcquisitionDeleveraging.deploy()).deployed(),
    (await ClosureDeleveraging.deploy()).deployed(),
    (await Depositing.deploy()).deployed(),
    (await Funding.deploy()).deployed(),
    (await IndexPriceMargin.deploy()).deployed(),
    (await MarketAdmin.deploy()).deployed(),
    (await NonceInvalidations.deploy()).deployed(),
    (await OraclePriceMargin.deploy()).deployed(),
    (await PositionBelowMinimumLiquidation.deploy()).deployed(),
    (await PositionInDeactivatedMarketLiquidation.deploy()).deployed(),
    (await Trading.deploy()).deployed(),
    (await Transferring.deploy()).deployed(),
    (await WalletLiquidation.deploy()).deployed(),
    (await Withdrawing.deploy()).deployed(),
  ]);

  return ethers.getContractFactory('Exchange_v4', {
    libraries: {
      AcquisitionDeleveraging: acquisitionDeleveraging.address,
      ClosureDeleveraging: closureDeleveraging.address,
      Depositing: depositing.address,
      Funding: funding.address,
      IndexPriceMargin: indexPriceMargin.address,
      MarketAdmin: marketAdmin.address,
      NonceInvalidations: nonceInvalidations.address,
      OraclePriceMargin: onChainPriceFeedMargin.address,
      PositionBelowMinimumLiquidation: positionBelowMinimumLiquidation.address,
      PositionInDeactivatedMarketLiquidation:
        positionInDeactivatedMarketLiquidation.address,
      Trading: trading.address,
      Transferring: transferring.address,
      WalletLiquidation: walletLiquidation.address,
      Withdrawing: withdrawing.address,
    },
  });
}

export async function executeTrade(
  exchange: Exchange_v4,
  dispatcherWallet: SignerWithAddress,
  indexPrice: IndexPrice | null,
  trader1: SignerWithAddress,
  trader2: SignerWithAddress,
) {
  if (indexPrice) {
    await exchange
      .connect(dispatcherWallet)
      .publishIndexPrices([indexPriceToArgumentStruct(indexPrice)]);
  }

  const sellOrder: Order = {
    signatureHashVersion,
    nonce: uuidv1({ msecs: new Date().getTime() - 100 * 60 * 60 * 1000 }),
    wallet: trader1.address,
    market: `${baseAssetSymbol}-USDC`,
    type: OrderType.Limit,
    side: OrderSide.Sell,
    quantity: '10.00000000',
    price: '2000.00000000',
  };
  const sellOrderSignature = await trader1.signMessage(
    ethers.utils.arrayify(getOrderHash(sellOrder)),
  );

  const buyOrder: Order = {
    signatureHashVersion,
    nonce: uuidv1({ msecs: new Date().getTime() - 100 * 60 * 60 * 1000 }),
    wallet: trader2.address,
    market: `${baseAssetSymbol}-USDC`,
    type: OrderType.Limit,
    side: OrderSide.Buy,
    quantity: '10.00000000',
    price: '2000.00000000',
  };
  const buyOrderSignature = await trader2.signMessage(
    ethers.utils.arrayify(getOrderHash(buyOrder)),
  );

  const trade: Trade = {
    baseAssetSymbol: baseAssetSymbol,
    quoteAssetSymbol: 'USD',
    baseQuantity: '10.00000000',
    quoteQuantity: '20000.00000000',
    makerFeeQuantity: '20.00000000',
    takerFeeQuantity: '40.00000000',
    price: '2000.00000000',
    makerSide: OrderSide.Sell,
  };

  await (
    await exchange
      .connect(dispatcherWallet)
      .executeOrderBookTrade(
        ...getExecuteOrderBookTradeArguments(
          buyOrder,
          buyOrderSignature,
          sellOrder,
          sellOrderSignature,
          trade,
        ),
      )
  ).wait();
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
          .deposit(
            decimalToAssetUnits(quantity, quoteAssetDecimals),
            ethers.constants.AddressZero,
          )
      ).wait(),
    ),
  );
}

function getNextPeriodInMs(periodsInFuture = 0) {
  return new Date(
    Math.round(
      new Date().getTime() + periodsInFuture * fundingPeriodLengthInMs,
    ),
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
