import BigNumber from 'bignumber.js';
import chai from 'chai';
import chaiAsPromised from 'chai-as-promised';
import { ethers } from 'hardhat';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { v1 as uuidv1 } from 'uuid';
import type { BigNumber as EthersBigNumber, Contract } from 'ethers';

chai.use(chaiAsPromised);
export const { expect } = chai;

import {
  decimalToAssetUnits,
  decimalToPips,
  getExecuteTradeArguments,
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
import { ChainlinkAggregatorMock, Exchange_v4, USDC } from '../typechain-types';

export const fieldUpgradeDelayInBlocks = (1 * 24 * 60 * 60) / 3;

export const quoteAssetDecimals = 6;

export const baseAssetSymbol = 'ETH';

export const quoteAssetSymbol = 'USD';

export async function addAndActivateMarket(
  chainlinkAggregator: ChainlinkAggregatorMock,
  dispatcherWallet: SignerWithAddress,
  exchange: Exchange_v4,
  baseAssetSymbol_ = baseAssetSymbol,
) {
  await exchange.addMarket({
    exists: true,
    isActive: false,
    baseAssetSymbol: baseAssetSymbol_,
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
  await exchange.connect(dispatcherWallet).activateMarket(baseAssetSymbol_);
}

export async function bootstrapLiquidatedWallet() {
  const [
    ownerWallet,
    dispatcherWallet,
    exitFundWallet,
    feeWallet,
    insuranceFundWallet,
    indexPriceServiceWallet,
    trader1Wallet,
    trader2Wallet,
  ] = await ethers.getSigners();
  const { exchange, governance, usdc } = await deployAndAssociateContracts(
    ownerWallet,
    dispatcherWallet,
    exitFundWallet,
    feeWallet,
    indexPriceServiceWallet,
    insuranceFundWallet,
  );

  await usdc.connect(dispatcherWallet).faucet(dispatcherWallet.address);

  await fundWallets(
    [trader1Wallet, trader2Wallet, insuranceFundWallet],
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
  );

  await exchange
    .connect(dispatcherWallet)
    .publishIndexPrices([indexPriceToArgumentStruct(liquidationIndexPrice)]);

  await exchange.connect(dispatcherWallet).liquidateWalletInMaintenance({
    counterpartyWallet: insuranceFundWallet.address,
    liquidatingWallet: trader1Wallet.address,
    liquidationQuoteQuantities: ['21980.00000000'].map(decimalToPips),
  });

  return {
    dispatcherWallet,
    exchange,
    governance,
    indexPriceServiceWallet,
    insuranceFundWallet,
    liquidationIndexPrice,
    liquidatedWallet: trader1Wallet,
    counterpartyWallet: trader2Wallet,
  };
}

const prices = [
  '2000.00000000',
  '2100.00000000',
  '1950.00000000',
  '1996.79000000',
  '1724.64000000',
];

export async function buildIndexPrice(
  indexPriceServiceWallet: SignerWithAddress,
  baseAssetSymbol_ = baseAssetSymbol,
): Promise<IndexPrice> {
  return buildIndexPriceWithTimestamp(
    indexPriceServiceWallet,
    (await getLatestBlockTimestampInSeconds()) * 1000 + 1000,
    baseAssetSymbol_,
  );
}

export async function buildIndexPriceWithTimestamp(
  indexPriceServiceWallet: SignerWithAddress,
  timestampInMs: number,
  baseAssetSymbol_ = baseAssetSymbol,
): Promise<IndexPrice> {
  const indexPrice = {
    signatureHashVersion,
    baseAssetSymbol: baseAssetSymbol_,
    timestampInMs,
    price: prices[0],
  };
  const signature = await indexPriceServiceWallet.signMessage(
    ethers.utils.arrayify(getIndexPriceHash(indexPrice, quoteAssetSymbol)),
  );

  return { ...indexPrice, signature };
}

export async function buildIndexPriceWithValue(
  indexPriceServiceWallet: SignerWithAddress,
  price: string,
  baseAssetSymbol_ = baseAssetSymbol,
): Promise<IndexPrice> {
  const indexPrice = {
    signatureHashVersion,
    baseAssetSymbol: baseAssetSymbol_,
    timestampInMs: (await getLatestBlockTimestampInSeconds()) * 1000 + 1000,
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

export async function deployContractsExceptCustodian(
  owner: SignerWithAddress,
  exitFundWallet: SignerWithAddress = owner,
  feeWallet: SignerWithAddress = owner,
  indexPriceServiceWallet: SignerWithAddress = owner,
  insuranceFund: SignerWithAddress = owner,
  governanceBlockDelay = 0,
  balanceMigrationSource?: string,
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
      await ExchangeFactory.connect(owner).deploy(
        balanceMigrationSource || ethers.constants.AddressZero,
        exitFundWallet.address,
        feeWallet.address,
        [indexPriceServiceWallet.address],
        insuranceFund.address,
        usdc.address,
      )
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
  indexPriceServiceWallet: SignerWithAddress = owner,
  insuranceFund: SignerWithAddress = owner,
  governanceBlockDelay = 0,
  addDefaultMarket = true,
  balanceMigrationSource?: string,
) {
  const { chainlinkAggregator, exchange, ExchangeFactory, governance, usdc } =
    await deployContractsExceptCustodian(
      owner,
      exitFundWallet,
      feeWallet,
      indexPriceServiceWallet,
      insuranceFund,
      governanceBlockDelay,
      balanceMigrationSource,
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
  ]);

  if (addDefaultMarket) {
    await addAndActivateMarket(chainlinkAggregator, dispatcher, exchange);
  }

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
    WalletExitAcquisitionDeleveraging,
    WalletInMaintenanceAcquisitionDeleveraging,
    WalletLiquidation,
    Withdrawing,
  ] = await Promise.all([
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
    ethers.getContractFactory('WalletExitAcquisitionDeleveraging'),
    ethers.getContractFactory('WalletInMaintenanceAcquisitionDeleveraging'),
    ethers.getContractFactory('WalletLiquidation'),
    ethers.getContractFactory('Withdrawing'),
  ]);

  const [
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
    walletExitAcquisitionDeleveraging,
    walletInMaintenanceAcquisitionDeleveraging,
    walletLiquidation,
    withdrawing,
  ] = await Promise.all([
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
    (await WalletExitAcquisitionDeleveraging.deploy()).deployed(),
    (await WalletInMaintenanceAcquisitionDeleveraging.deploy()).deployed(),
    (await WalletLiquidation.deploy()).deployed(),
    (await Withdrawing.deploy()).deployed(),
  ]);

  return ethers.getContractFactory('Exchange_v4', {
    libraries: {
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
      WalletExitAcquisitionDeleveraging:
        walletExitAcquisitionDeleveraging.address,
      WalletInMaintenanceAcquisitionDeleveraging:
        walletInMaintenanceAcquisitionDeleveraging.address,
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
  baseAssetSymbol_ = baseAssetSymbol,
  price = '2000.00000000',
  quantity = '10.00000000',
): Promise<Trade> {
  if (indexPrice) {
    await exchange
      .connect(dispatcherWallet)
      .publishIndexPrices([indexPriceToArgumentStruct(indexPrice)]);
  }

  const sellOrder: Order = {
    signatureHashVersion,
    nonce: uuidv1({ msecs: new Date().getTime() - 100 * 60 * 60 * 1000 }),
    wallet: trader1.address,
    market: `${baseAssetSymbol_}-USD`,
    type: OrderType.Limit,
    side: OrderSide.Sell,
    quantity,
    price,
  };
  const sellOrderSignature = await trader1.signMessage(
    ethers.utils.arrayify(getOrderHash(sellOrder)),
  );

  const buyOrder: Order = {
    signatureHashVersion,
    nonce: uuidv1({ msecs: new Date().getTime() - 100 * 60 * 60 * 1000 }),
    wallet: trader2.address,
    market: `${baseAssetSymbol_}-USD`,
    type: OrderType.Limit,
    side: OrderSide.Buy,
    quantity,
    price,
  };
  const buyOrderSignature = await trader2.signMessage(
    ethers.utils.arrayify(getOrderHash(buyOrder)),
  );

  const trade: Trade = {
    baseAssetSymbol: baseAssetSymbol,
    baseQuantity: quantity,
    quoteQuantity: new BigNumber(quantity)
      .times(new BigNumber(price))
      .toFixed(8),
    makerFeeQuantity: '20.00000000',
    takerFeeQuantity: '40.00000000',
    price,
    makerSide: OrderSide.Sell,
  };

  await (
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
      )
  ).wait();

  return trade;
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

export async function getLatestBlockTimestampInSeconds(): Promise<number> {
  return (await ethers.provider.getBlock('latest')).timestamp;
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
  baseAssetSymbols: string[],
) {
  console.log(
    `USD balance: ${pipToDecimal(
      await exchange.loadBalanceBySymbol(wallet, 'USD'),
    )}`,
  );

  for (const baseAssetSymbol of baseAssetSymbols) {
    console.log(
      `${baseAssetSymbol} balance:  ${pipToDecimal(
        await exchange.loadBalanceBySymbol(wallet, baseAssetSymbol),
      )}`,
    );
    console.log(
      `${baseAssetSymbol} cost basis: ${pipToDecimal(
        (await exchange.loadBalanceStructBySymbol(wallet, baseAssetSymbol))
          .costBasis,
      )}`,
    );
  }

  console.log(
    `Total account value: ${pipToDecimal(
      await exchange.loadTotalAccountValueFromIndexPrices(wallet),
    )}`,
  );
  console.log(
    `Outstanding funding payments: ${pipToDecimal(
      await exchange.loadOutstandingWalletFunding(wallet),
    )}`,
  );
  console.log(
    `Initial margin requirement: ${pipToDecimal(
      await exchange.loadTotalInitialMarginRequirementFromIndexPrices(wallet),
    )}`,
  );
  console.log(
    `Maintenance margin requirement: ${pipToDecimal(
      await exchange.loadTotalMaintenanceMarginRequirementFromIndexPrices(
        wallet,
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
