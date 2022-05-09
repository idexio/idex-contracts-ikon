import { expect } from 'chai';
import { ethers } from 'hardhat';
import { v1 as uuidv1 } from 'uuid';

import { decimalToPips, getWithdrawalHash, getWithdrawArguments } from '../lib';

const collateralAssetDecimals = 6;

describe('Exchange', function () {
  it('Should work', async function () {
    const USDC = await ethers.getContractFactory('USDC');
    const Exchange_v4 = await ethers.getContractFactory('Exchange_v4');
    const Governance = await ethers.getContractFactory('Governance');
    const Custodian = await ethers.getContractFactory('Custodian');

    const usdc = await (await USDC.deploy()).deployed();

    const [owner, dispatcher, trader] = await ethers.getSigners();

    const [exchange, governance] = await Promise.all([
      (
        await Exchange_v4.deploy(
          ethers.constants.AddressZero,
          usdc.address,
          'USDC',
          collateralAssetDecimals,
          owner.address,
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
    expect(depositedEvents.length).to.equal(1);
    expect(depositedEvents[0].args?.quantityInPips).to.equal(
      decimalToPips('1.00000000'),
    );

    /*
    expect(await greeter.greet()).to.equal('Hello, world!');

    const setGreetingTx = await greeter.setGreeting('Hola, mundo!');

    // wait until the transaction is mined
    await setGreetingTx.wait();

    expect(await greeter.greet()).to.equal('Hola, mundo!');
    */
  });
});
