import type { BigNumber as EthersBigNumber } from 'ethers';
import BigNumber from 'bignumber.js';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import { v1 as uuidv1 } from 'uuid';

import {
  decimalToAssetUnits,
  decimalToPips,
  getDelegatedKeyAuthorizationHash,
  getExecuteOrderBookTradeArguments,
  getOraclePriceHash,
  getOrderHash,
  getWithdrawalHash,
  getWithdrawArguments,
  OraclePrice,
  Order,
  OrderSide,
  OrderType,
  pipsDecimals,
  signatureHashVersion,
  Trade,
} from '../lib';

const collateralAssetDecimals = 6;

const millisecondsInAnHour = 60 * 60 * 1000;

describe('Exchange', function () {
  it('deposit and withdraw should work', async function () {
    const [owner, dispatcher, trader, oracle] = await ethers.getSigners();
    const { exchange, usdc } = await deployAndAssociateContracts(
      owner,
      dispatcher,
      oracle,
    );

    const depositQuantity = ethers.utils.parseUnits(
      '1.0',
      collateralAssetDecimals,
    );
    await usdc.transfer(trader.address, depositQuantity);
    await usdc.connect(trader).approve(exchange.address, depositQuantity);
    await (await exchange.connect(trader).deposit(depositQuantity)).wait();

    const depositedEvents = await exchange.queryFilter(
      exchange.filters.Deposited(),
    );
    expect(depositedEvents.length).to.equal(1);
    expect(depositedEvents[0].args?.quantityInPips).to.equal(
      decimalToPips('1.00000000'),
    );

    const withdrawal = {
      nonce: uuidv1(),
      wallet: trader.address,
      quantity: '1.00000000',
    };
    const signature = await trader.signMessage(
      ethers.utils.arrayify(getWithdrawalHash(withdrawal)),
    );
    await (
      await exchange
        .connect(dispatcher)
        .withdraw(...getWithdrawArguments(withdrawal, '0.00000000', signature))
    ).wait();

    const withdrawnEvents = await exchange.queryFilter(
      exchange.filters.Withdrawn(),
    );
    expect(withdrawnEvents.length).to.equal(1);
    expect(withdrawnEvents.length).to.equal(1);
    expect(withdrawnEvents[0].args?.quantityInPips).to.equal(
      decimalToPips('1.00000000'),
    );
  });

  it('publishFundingMutipliers should work', async function () {
    const [owner, dispatcher, oracle] = await ethers.getSigners();
    const { exchange } = await deployAndAssociateContracts(
      owner,
      dispatcher,
      oracle,
    );

    const oraclePrice = await buildOraclePrice(oracle);
    const fundingRateInPips = '-16100';

    await (
      await exchange
        .connect(dispatcher)
        .publishFundingMutipliers([oraclePrice], [fundingRateInPips])
    ).wait();
  });

  it.only('executeOrderBookTrade should work', async function () {
    const [
      owner,
      dispatcher,
      oracle,
      trader1,
      trader2,
      trader1Delegate,
      feeWallet,
    ] = await ethers.getSigners();
    const { exchange, usdc } = await deployAndAssociateContracts(
      owner,
      dispatcher,
      oracle,
      feeWallet,
    );

    await Promise.all([
      (
        await usdc.transfer(
          trader1.address,
          decimalToAssetUnits('1000.00000000', collateralAssetDecimals),
        )
      ).wait(),
      (
        await usdc.transfer(
          trader2.address,
          decimalToAssetUnits('1000.00000000', collateralAssetDecimals),
        )
      ).wait(),
    ]);

    await Promise.all([
      (
        await usdc
          .connect(trader1)
          .approve(
            exchange.address,
            decimalToAssetUnits('1000.00000000', collateralAssetDecimals),
          )
      ).wait(),
      (
        await usdc
          .connect(trader2)
          .approve(
            exchange.address,
            decimalToAssetUnits('1000.00000000', collateralAssetDecimals),
          )
      ).wait(),
    ]);

    await Promise.all([
      (
        await exchange
          .connect(trader1)
          .deposit(
            decimalToAssetUnits('1000.00000000', collateralAssetDecimals),
          )
      ).wait(),
      (
        await exchange
          .connect(trader2)
          .deposit(
            decimalToAssetUnits('1000.00000000', collateralAssetDecimals),
          )
      ).wait(),
    ]);

    await (await exchange.setDelegateKeyExpirationPeriod(10000000)).wait();

    const trader1DelegatedKeyAuthorization = {
      delegatedPublicKey: trader1Delegate.address,
      nonce: uuidv1({ msecs: new Date().getTime() - 1000 }),
    };
    const trader1DelegatedKeyAuthorizationSignature = await trader1.signMessage(
      ethers.utils.arrayify(
        getDelegatedKeyAuthorizationHash(
          trader1.address,
          trader1DelegatedKeyAuthorization,
        ),
      ),
    );
    const sellDelegatedKeyAuthorization = {
      ...trader1DelegatedKeyAuthorization,
      signature: trader1DelegatedKeyAuthorizationSignature,
    };

    const sellOrder: Order = {
      signatureHashVersion,
      nonce: uuidv1(),
      wallet: trader1.address,
      market: 'ETH-USDC',
      type: OrderType.Limit,
      side: OrderSide.Sell,
      quantity: '1.00000000',
      isQuantityInQuote: false,
      price: '2000.00000000',
    };
    const sellOrderSignature = await trader1Delegate.signMessage(
      ethers.utils.arrayify(
        getOrderHash(sellOrder, sellDelegatedKeyAuthorization),
      ),
    );

    const buyOrder: Order = {
      signatureHashVersion,
      nonce: uuidv1(),
      wallet: trader2.address,
      market: 'ETH-USDC',
      type: OrderType.Limit,
      side: OrderSide.Buy,
      quantity: '1.00000000',
      isQuantityInQuote: false,
      price: '2000.00000000',
    };
    const buyOrderSignature = await trader2.signMessage(
      ethers.utils.arrayify(getOrderHash(buyOrder)),
    );

    const trade: Trade = {
      baseAssetSymbol: 'ETH',
      quoteAssetSymbol: 'USD',
      baseQuantity: '1.00000000',
      quoteQuantity: '2000.00000000',
      makerFeeQuantity: '2.00000000',
      takerFeeQuantity: '4.00000000',
      price: '1.00000000',
      makerSide: OrderSide.Sell,
    };

    const oraclePrice = await buildOraclePrice(oracle);

    await (
      await exchange
        .connect(dispatcher)
        .executeOrderBookTrade(
          ...getExecuteOrderBookTradeArguments(
            buyOrder,
            buyOrderSignature,
            sellOrder,
            sellOrderSignature,
            trade,
            [oraclePrice],
            undefined,
            sellDelegatedKeyAuthorization,
          ),
        )
    ).wait();

    console.log('Trader1');
    console.log(
      `USDC balance: ${pipToDecimal(
        await exchange.loadBalanceInPipsBySymbol(trader1.address, 'USDC'),
      )}`,
    );
    console.log(
      `ETH balance:  ${pipToDecimal(
        await exchange.loadBalanceInPipsBySymbol(trader1.address, 'ETH'),
      )}`,
    );
    console.log(
      `Total account value: ${pipToDecimal(
        await exchange.calculateTotalAccountValue(trader1.address, [
          await buildOraclePrice(oracle),
        ]),
      )}`,
    );
    console.log(
      `Initial margin requirement: ${pipToDecimal(
        await exchange.calculateTotalInitialMarginRequirement(trader1.address, [
          await buildOraclePrice(oracle),
        ]),
      )}`,
    );

    console.log('Trader2');
    console.log(
      `USDC balance: ${pipToDecimal(
        await exchange.loadBalanceInPipsBySymbol(trader2.address, 'USDC'),
      )}`,
    );
    console.log(
      `ETH balance:  ${pipToDecimal(
        await exchange.loadBalanceInPipsBySymbol(trader2.address, 'ETH'),
      )}`,
    );
    console.log(
      `Total account value: ${pipToDecimal(
        await exchange.calculateTotalAccountValue(trader2.address, [
          await buildOraclePrice(oracle),
        ]),
      )}`,
    );
    console.log(
      `Initial margin requirement: ${pipToDecimal(
        await exchange.calculateTotalInitialMarginRequirement(trader2.address, [
          await buildOraclePrice(oracle),
        ]),
      )}`,
    );
  });
});

async function deployAndAssociateContracts(
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
async function buildOraclePrice(
  oracle: SignerWithAddress,
): Promise<OraclePrice> {
  const oraclePrice = {
    baseAssetSymbol: 'ETH',
    timestampInMs: getPastHourInMs(),
    priceInAssetUnits: '2000000000',
    fundingRateInPips: '-16100',
  };
  const signature = await oracle.signMessage(
    ethers.utils.arrayify(getOraclePriceHash(oraclePrice)),
  );

  return { ...oraclePrice, signature };
}

function getPastHourInMs(hoursAgo = 0) {
  return new Date(
    Math.round(
      (new Date().getTime() - hoursAgo * millisecondsInAnHour) /
        millisecondsInAnHour,
    ) * millisecondsInAnHour,
  ).getTime();
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
const pipToDecimal = function pipToDecimal(pips: EthersBigNumber): string {
  const bn = new BigNumber(pips.toString());
  return bn.shiftedBy(pipsDecimals * -1).toFixed(pipsDecimals);
};
