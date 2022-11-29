import BigNumber from 'bignumber.js';
import { ethers } from 'hardhat';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { v1 as uuidv1 } from 'uuid';
import type { BigNumber as EthersBigNumber, Contract } from 'ethers';

import {
  decimalToAssetUnits,
  decimalToPips,
  getOraclePriceHash,
  getOrderHash,
  OraclePrice,
  Order,
  OrderSide,
  OrderType,
  pipsDecimals,
  signatureHashVersion,
} from '../lib';

export const quoteAssetDecimals = 6;

const millisecondsInAnHour = 60 * 60 * 1000;

export async function buildOraclePrice(
  oracle: SignerWithAddress,
): Promise<OraclePrice> {
  return (await buildOraclePrices(oracle, 1))[0];
}

const prices = [
  '2000000000',
  '2100000000',
  '1950000000',
  '1996790000',
  '1724640000',
];
export async function buildOraclePrices(
  oracle: SignerWithAddress,
  count = 1,
): Promise<OraclePrice[]> {
  return Promise.all(
    Array(count)
      .fill(null)
      .map(async (_, i) => {
        const oraclePrice = {
          baseAssetSymbol: 'ETH',
          timestampInMs: getPastHourInMs(count - i),
          priceInAssetUnits: prices[i % prices.length],
        };
        const signature = await oracle.signMessage(
          ethers.utils.arrayify(getOraclePriceHash(oraclePrice)),
        );

        return { ...oraclePrice, signature };
      }),
  );
}

export async function buildOraclePriceWithValue(
  oracle: SignerWithAddress,
  priceInAssetUnits: string,
  baseAssetSymbol = 'ETH',
): Promise<OraclePrice> {
  const oraclePrice = {
    baseAssetSymbol,
    timestampInMs: new Date().getTime(),
    priceInAssetUnits,
  };
  const signature = await oracle.signMessage(
    ethers.utils.arrayify(getOraclePriceHash(oraclePrice)),
  );

  return { ...oraclePrice, signature };
}

export async function buildLimitOrder(
  signer: SignerWithAddress,
  side: OrderSide,
  market = 'ETH-USDC',
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
  oracle: SignerWithAddress = owner,
) {
  const [
    AcquisitionDeleveraging,
    ClosureDeleveraging,
    Depositing,
    Funding,
    Liquidation,
    Margin,
    MarketAdmin,
    NonceInvalidations,
    Trading,
    Withdrawing,
  ] = await Promise.all([
    ethers.getContractFactory('AcquisitionDeleveraging'),
    ethers.getContractFactory('ClosureDeleveraging'),
    ethers.getContractFactory('Depositing'),
    ethers.getContractFactory('Funding'),
    ethers.getContractFactory('Liquidation'),
    ethers.getContractFactory('Margin'),
    ethers.getContractFactory('MarketAdmin'),
    ethers.getContractFactory('NonceInvalidations'),
    ethers.getContractFactory('Trading'),
    ethers.getContractFactory('Withdrawing'),
  ]);
  const [
    acquisitionDeleveraging,
    closureDeleveraging,
    depositing,
    funding,
    liquidation,
    margin,
    marketAdmin,
    nonceInvalidations,
    trading,
    withdrawing,
  ] = await Promise.all([
    (await AcquisitionDeleveraging.deploy()).deployed(),
    (await ClosureDeleveraging.deploy()).deployed(),
    (await Depositing.deploy()).deployed(),
    (await Funding.deploy()).deployed(),
    (await Liquidation.deploy()).deployed(),
    (await Margin.deploy()).deployed(),
    (await MarketAdmin.deploy()).deployed(),
    (await NonceInvalidations.deploy()).deployed(),
    (await Trading.deploy()).deployed(),
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
          Liquidation: liquidation.address,
          Margin: margin.address,
          MarketAdmin: marketAdmin.address,
          NonceInvalidations: nonceInvalidations.address,
          Trading: trading.address,
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
        oracle.address,
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
        baseAssetSymbol: 'ETH',
        chainlinkPriceFeedAddress: chainlinkAggregator.address,
        initialMarginFractionInPips: '5000000',
        maintenanceMarginFractionInPips: '3000000',
        incrementalInitialMarginFractionInPips: '1000000',
        baselinePositionSizeInPips: '14000000000',
        incrementalPositionSizeInPips: '2800000000',
        maximumPositionSizeInPips: '282000000000',
        minimumPositionSizeInPips: '2000000000',
        lastOraclePriceTimestampInMs: 0,
        oraclePriceInPipsAtDeactivation: 0,
      })
    ).wait(),
  ]);
  (await exchange.connect(dispatcher).activateMarket('ETH')).wait();

  return { chainlinkAggregator, usdc, custodian, exchange, governance };
}

export async function fundWallets(
  wallets: SignerWithAddress[],
  exchange: Contract,
  usdc: Contract,
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

function getPastHourInMs(hoursAgo = 0) {
  return new Date(
    Math.round(
      (new Date().getTime() - hoursAgo * millisecondsInAnHour) /
        millisecondsInAnHour,
    ) * millisecondsInAnHour,
  ).getTime();
}

export async function logWalletBalances(
  wallet: string,
  exchange: Contract,
  oraclePrices: OraclePrice[],
) {
  console.log(
    `USDC balance: ${pipToDecimal(
      await exchange.loadBalanceInPipsBySymbol(wallet, 'USDC'),
    )}`,
  );

  for (const oraclePrice of oraclePrices) {
    console.log(
      `${oraclePrice.baseAssetSymbol} balance:  ${pipToDecimal(
        await exchange.loadBalanceInPipsBySymbol(
          wallet,
          oraclePrice.baseAssetSymbol,
        ),
      )}`,
    );
    console.log(
      `${oraclePrice.baseAssetSymbol} cost basis: ${pipToDecimal(
        (
          await exchange.loadBalanceBySymbol(
            wallet,
            oraclePrice.baseAssetSymbol,
          )
        ).costBasisInPips,
      )}`,
    );
  }

  console.log(
    `Total account value: ${pipToDecimal(
      await exchange.loadTotalAccountValue(wallet, oraclePrices),
    )}`,
  );
  console.log(
    `Outstanding funding payments: ${pipToDecimal(
      await exchange.loadOutstandingWalletFunding(wallet),
    )}`,
  );
  console.log(
    `Initial margin requirement: ${pipToDecimal(
      await exchange.loadTotalInitialMarginRequirement(wallet, oraclePrices),
    )}`,
  );
  console.log(
    `Maintenance margin requirement: ${pipToDecimal(
      await exchange.loadTotalMaintenanceMarginRequirement(
        wallet,
        oraclePrices,
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
