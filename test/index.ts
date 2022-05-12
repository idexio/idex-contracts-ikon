import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import { v1 as uuidv1 } from 'uuid';

import {
  decimalToPips,
  getExecuteOrderBookTradeArguments,
  getOraclePriceHash,
  getOrderHash,
  getWithdrawalHash,
  getWithdrawArguments,
  Order,
  OrderSide,
  OrderType,
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

    const oraclePrice = {
      baseAssetSymbol: 'ETH',
      timestampInMs: getPastHourInMs(),
      priceInAssetUnits: '2023630000',
      fundingRateInPips: '-16100',
    };
    const signature = await oracle.signMessage(
      ethers.utils.arrayify(getOraclePriceHash(oraclePrice)),
    );
    await (
      await exchange
        .connect(dispatcher)
        .publishFundingMutipliers([{ ...oraclePrice, signature }])
    ).wait();
  });

  it.only('executeOrderBookTrade should work', async function () {
    const [owner, dispatcher, oracle, trader1, trader2, feeWallet] =
      await ethers.getSigners();
    const { exchange } = await deployAndAssociateContracts(
      owner,
      dispatcher,
      oracle,
      feeWallet,
    );

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
    const sellOrderSignature = await trader1.signMessage(
      ethers.utils.arrayify(getOrderHash(sellOrder)),
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
          ),
        )
    ).wait();

    console.log(
      await exchange.loadBalanceInPipsBySymbol(trader1.address, 'USDC'),
    );
    console.log(
      await exchange.loadBalanceInPipsBySymbol(trader1.address, 'ETH'),
    );
    console.log(
      await exchange.loadBalanceInPipsBySymbol(trader2.address, 'USDC'),
    );
    console.log(
      await exchange.loadBalanceInPipsBySymbol(trader2.address, 'ETH'),
    );
    console.log(
      await exchange.loadBalanceInPipsBySymbol(feeWallet.address, 'USDC'),
    );
    console.log(
      await exchange.loadBalanceInPipsBySymbol(feeWallet.address, 'ETH'),
    );
  });
});

async function deployAndAssociateContracts(
  owner: SignerWithAddress,
  dispatcher: SignerWithAddress = owner,
  oracle: SignerWithAddress = owner,
  feeWallet: SignerWithAddress = owner,
) {
  const [Depositing, Trading, Withdrawing] = await Promise.all([
    ethers.getContractFactory('Depositing'),
    ethers.getContractFactory('Trading'),
    ethers.getContractFactory('Withdrawing'),
  ]);
  const [depositing, trading, withdrawing] = await Promise.all([
    (await Depositing.deploy()).deployed(),
    (await Trading.deploy()).deployed(),
    (await Withdrawing.deploy()).deployed(),
  ]);

  const [USDC, Exchange_v4, Governance, Custodian] = await Promise.all([
    ethers.getContractFactory('USDC'),
    ethers.getContractFactory('Exchange_v4', {
      libraries: {
        Depositing: depositing.address,
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
        '300',
        '500',
        '100',
        '14000000000',
        '2800000000',
        '282000000000',
      )
    ).wait(),
  ]);

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
