import { ethers } from 'hardhat';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

import {
  Custodian,
  Custodian__factory,
  Exchange_v4,
  Exchange_v4__factory,
  ExchangeWithdrawMock,
  ExchangeWithdrawMock__factory,
  Governance,
  GovernanceMock,
  GovernanceMock__factory,
  Governance__factory,
  USDC,
  USDC__factory,
} from '../typechain-types';
import {
  deployContractsExceptCustodian,
  expect,
  quoteAssetDecimals,
} from './helpers';

describe('Custodian', function () {
  let CustodianFactory: Custodian__factory;
  let ExchangeWithdrawMockFactory: ExchangeWithdrawMock__factory;
  let GovernanceFactory: Governance__factory;
  let GovernanceMockFactory: GovernanceMock__factory;
  let USDCFactory: USDC__factory;

  beforeEach(async () => {
    [
      CustodianFactory,
      ExchangeWithdrawMockFactory,
      GovernanceFactory,
      GovernanceMockFactory,
      USDCFactory,
    ] = await Promise.all([
      ethers.getContractFactory('Custodian'),
      ethers.getContractFactory('ExchangeWithdrawMock'),
      ethers.getContractFactory('Governance'),
      ethers.getContractFactory('GovernanceMock'),
      ethers.getContractFactory('USDC'),
    ]);
  });

  describe('deploy', async function () {
    let exchange: Exchange_v4;
    let governance: Governance;

    beforeEach(async () => {
      const [owner] = await ethers.getSigners();
      const results = await deployContractsExceptCustodian(owner);
      exchange = results.exchange;
      governance = results.governance;
    });

    it('should work', async () => {
      await CustodianFactory.deploy(exchange.address, governance.address);
    });

    it('should revert for invalid exchange address', async () => {
      await expect(
        CustodianFactory.deploy(
          ethers.constants.AddressZero,
          governance.address,
        ),
      ).to.eventually.be.rejectedWith(/invalid exchange contract address/i);
    });

    it('should revert for invalid governance address', async () => {
      await expect(
        CustodianFactory.deploy(exchange.address, ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/invalid exchange contract address/i);
    });
  });

  describe('setExchange', () => {
    let custodian: Custodian;
    let ExchangeFactory: Exchange_v4__factory;
    let governanceMock: GovernanceMock;
    let ownerWallet: SignerWithAddress;
    let usdc: USDC;

    beforeEach(async () => {
      [ownerWallet] = await ethers.getSigners();
      const results = await deployContractsExceptCustodian(ownerWallet);
      ExchangeFactory = results.ExchangeFactory;
      usdc = results.usdc;
      governanceMock = await GovernanceMockFactory.deploy();
      custodian = await CustodianFactory.deploy(
        results.exchange.address,
        governanceMock.address,
      );
      governanceMock.setCustodian(custodian.address);
    });

    it('should work when sent from governance address', async () => {
      const newExchange = await ExchangeFactory.deploy(
        ethers.constants.AddressZero,
        ownerWallet.address,
        ownerWallet.address,
        [ownerWallet.address],
        ownerWallet.address,
        usdc.address,
      );

      await governanceMock.setExchange(newExchange.address);

      expect(custodian.queryFilter(custodian.filters.ExchangeChanged()))
        .to.eventually.be.an('array')
        .with.lengthOf(2);
    });

    it('should revert for invalid address', async () => {
      await expect(
        governanceMock.setExchange(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/invalid contract address/i);
    });

    it('should revert for non-contract address', async () => {
      await expect(
        governanceMock.setExchange(ownerWallet.address),
      ).to.eventually.be.rejectedWith(/invalid contract address/i);
    });

    it('should revert when not sent from governance address', async () => {
      await expect(
        custodian
          .connect((await ethers.getSigners())[1])
          .setExchange(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/caller must be governance/i);
    });
  });

  describe('setGovernance', () => {
    let custodian: Custodian;
    let governanceMock: GovernanceMock;
    let ownerWallet: SignerWithAddress;

    beforeEach(async () => {
      [ownerWallet] = await ethers.getSigners();
      const results = await deployContractsExceptCustodian(ownerWallet);
      governanceMock = await GovernanceMockFactory.deploy();
      custodian = await CustodianFactory.deploy(
        results.exchange.address,
        governanceMock.address,
      );
      governanceMock.setCustodian(custodian.address);
    });

    it('should work when sent from governance address', async () => {
      const newGovernance = await GovernanceFactory.deploy(0);

      await governanceMock.setGovernance(newGovernance.address);

      expect(custodian.queryFilter(custodian.filters.GovernanceChanged()))
        .to.eventually.be.an('array')
        .with.lengthOf(2);
    });

    it('should revert for invalid address', async () => {
      await expect(
        governanceMock.setGovernance(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/invalid contract address/i);
    });

    it('should revert for non-contract address', async () => {
      await expect(
        governanceMock.setGovernance(ownerWallet.address),
      ).to.eventually.be.rejectedWith(/invalid contract address/i);
    });

    it('should revert when not sent from governance address', async () => {
      await expect(
        custodian
          .connect((await ethers.getSigners())[1])
          .setGovernance(ethers.constants.AddressZero),
      ).to.eventually.be.rejectedWith(/caller must be governance/i);
    });
  });

  describe('withdraw', () => {
    let custodian: Custodian;
    let exchangeWithdrawMock: ExchangeWithdrawMock;
    let governance: Governance;
    let usdc: USDC;

    beforeEach(async () => {
      exchangeWithdrawMock = await ExchangeWithdrawMockFactory.deploy();
      governance = await GovernanceFactory.deploy(0);
      custodian = await CustodianFactory.deploy(
        exchangeWithdrawMock.address,
        governance.address,
      );
      await exchangeWithdrawMock.setCustodian(custodian.address);
      usdc = await (await USDCFactory.deploy()).deployed();
    });

    it('should work when sent from exchange', async () => {
      const depositQuantity = ethers.utils.parseUnits(
        '5.0',
        quoteAssetDecimals,
      );
      const destinationWallet = (await ethers.getSigners())[1];

      await usdc.transfer(custodian.address, depositQuantity);
      await exchangeWithdrawMock.withdraw(
        destinationWallet.address,
        usdc.address,
        depositQuantity,
      );
    });

    it('should revert when not sent from exchange', async () => {
      await expect(
        custodian.withdraw(
          (
            await ethers.getSigners()
          )[1].address,
          usdc.address,
          '100000000',
        ),
      ).to.eventually.be.rejectedWith(/caller must be exchange/i);
    });
  });
});
