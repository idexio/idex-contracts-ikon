import BigNumber from 'bignumber.js';
import { ethers } from 'hardhat';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { v1 as uuidv1 } from 'uuid';
import type { BigNumber as EthersBigNumber, Contract } from 'ethers';

import {
  decimalToAssetUnits,
  getOraclePriceHash,
  getOrderHash,
  OraclePrice,
  Order,
  OrderSide,
  OrderType,
  pipsDecimals,
  signatureHashVersion,
} from '../lib';

export const collateralAssetDecimals = 6;

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
    isQuantityInQuote: false,
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
  oracle: SignerWithAddress = owner,
  feeWallet: SignerWithAddress = owner,
) {
  const [Depositing, NonceInvalidations, Perpetual, Trading, Withdrawing] =
    await Promise.all([
      ethers.getContractFactory('Depositing'),
      ethers.getContractFactory('NonceInvalidations'),
      ethers.getContractFactory('Perpetual'),
      ethers.getContractFactory('Trading'),
      ethers.getContractFactory('Withdrawing'),
    ]);
  const [depositing, nonceInvalidations, perpetual, trading, withdrawing] =
    await Promise.all([
      (await Depositing.deploy()).deployed(),
      (await NonceInvalidations.deploy()).deployed(),
      (await Perpetual.deploy()).deployed(),
      (await Trading.deploy()).deployed(),
      (await Withdrawing.deploy()).deployed(),
    ]);

  const [USDC, Exchange_v4, Governance, Custodian] = await Promise.all([
    ethers.getContractFactory('USDC'),
    ethers.getContractFactory('Exchange_v4', {
      libraries: {
        Depositing: depositing.address,
        NonceInvalidations: nonceInvalidations.address,
        Perpetual: perpetual.address,
        Trading: trading.address,
        Withdrawing: withdrawing.address,
      },
    }),
    ethers.getContractFactory('Governance'),
    ethers.getContractFactory('Custodian'),
  ]);

  const usdc = await (await USDC.deploy()).deployed();

  const [exchange, governance] = await Promise.all([
    (
      await Exchange_v4.deploy(
        ethers.constants.AddressZero,
        usdc.address,
        'USDC',
        collateralAssetDecimals,
        feeWallet.address,
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
      await exchange.addMarket(
        'ETH',
        '5000000',
        '3000000',
        '1000000',
        '14000000000',
        '2800000000',
        '282000000000',
      )
    ).wait(),
  ]);

  return { custodian, exchange, governance, usdc };
}

export async function fundWallets(
  wallets: SignerWithAddress[],
  exchange: Contract,
  usdc: Contract,
  quantity = '1000.00000000',
) {
  await Promise.all(
    wallets.map(async (wallet) =>
      (
        await usdc.transfer(
          wallet.address,
          decimalToAssetUnits(quantity, collateralAssetDecimals),
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
            decimalToAssetUnits(quantity, collateralAssetDecimals),
          )
      ).wait(),
    ),
  );

  await Promise.all(
    wallets.map(async (wallet) =>
      (
        await exchange
          .connect(wallet)
          .deposit(decimalToAssetUnits(quantity, collateralAssetDecimals))
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
  walletAddress: string,
  exchange: Contract,
  oraclePrices: OraclePrice[],
) {
  console.log(
    `USDC balance: ${pipToDecimal(
      await exchange.loadBalanceInPipsBySymbol(walletAddress, 'USDC'),
    )}`,
  );
  console.log(
    `ETH balance:  ${pipToDecimal(
      await exchange.loadBalanceInPipsBySymbol(walletAddress, 'ETH'),
    )}`,
  );
  console.log(
    `Total account value: ${pipToDecimal(
      await exchange.calculateTotalAccountValue(walletAddress, oraclePrices),
    )}`,
  );
  console.log(
    `Initial margin requirement: ${pipToDecimal(
      await exchange.calculateTotalInitialMarginRequirement(
        walletAddress,
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
