import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import { v1 as uuidv1 } from 'uuid';

import {
  decimalToPips,
  getOraclePriceHash,
  getWithdrawalHash,
  getWithdrawArguments,
} from '../lib';

const collateralAssetDecimals = 6;

const millisecondsInAnHour = 60 * 60 * 1000;

describe('Exchange', function () {
  it('deposit and withdraw should work', async function () {
    const [owner, dispatcher, trader, oracle] = await ethers.getSigners();
    const { exchange } = await deployAndAssociateContracts(
      owner,
      dispatcher,
      trader,
      oracle,
    );

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
    const [owner, dispatcher, trader, oracle] = await ethers.getSigners();
    const { exchange } = await deployAndAssociateContracts(
      owner,
      dispatcher,
      trader,
      oracle,
    );

    await (
      await exchange.addMarket(
        'ETH',
        '300',
        '500',
        '100',
        '14000000000',
        '2800000000',
        '282000000000',
      )
    ).wait();

    const oraclePrice = {
      baseAssetSymbol: 'ETH',
      timestampInMs: getPastHourInMs(),
      priceInAssetUnits: '2023630000',
      fundingRateInPercentagePips: '-161000000',
    };
    const signature = await oracle.signMessage(
      ethers.utils.arrayify(getOraclePriceHash(oraclePrice)),
    );
    await (
      await exchange
        .connect(dispatcher)
        .publishFundingMutipliers([{ ...oraclePrice, signature }])
    ).wait();

    console.log(
      await exchange.loadBalanceInPipsBySymbol(trader.address, 'USDC'),
    );

    await (await exchange.updateAccountFunding(trader.address)).wait();

    console.log(
      await exchange.loadBalanceInPipsBySymbol(trader.address, 'USDC'),
    );
  });
});

async function deployAndAssociateContracts(
  owner: SignerWithAddress,
  dispatcher: SignerWithAddress = owner,
  trader: SignerWithAddress = owner,
  oracle: SignerWithAddress = owner,
) {
  const USDC = await ethers.getContractFactory('USDC');
  const Exchange_v4 = await ethers.getContractFactory('Exchange_v4');
  const Governance = await ethers.getContractFactory('Governance');
  const Custodian = await ethers.getContractFactory('Custodian');

  const usdc = await (await USDC.deploy()).deployed();

  const [exchange, governance] = await Promise.all([
    (
      await Exchange_v4.deploy(
        ethers.constants.AddressZero,
        usdc.address,
        'USDC',
        collateralAssetDecimals,
        owner.address,
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
  ]);

  const depositQuantity = ethers.utils.parseUnits(
    '1.0',
    collateralAssetDecimals,
  );
  await usdc.transfer(trader.address, depositQuantity);
  await usdc.connect(trader).approve(exchange.address, depositQuantity);
  await (await exchange.connect(trader).deposit(depositQuantity)).wait();

  return { custodian, exchange, governance, usdc };
}

function getPastHourInMs(hoursAgo = 0) {
  return new Date(
    Math.round(
      (new Date().getTime() - hoursAgo * millisecondsInAnHour) /
        millisecondsInAnHour,
    ) * millisecondsInAnHour,
  ).getTime();
}
