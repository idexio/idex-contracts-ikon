import { ethers } from 'hardhat';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

import { ethAddress } from '../lib';
import {
  Custodian,
  Custodian__factory,
  Exchange_v4,
  Exchange_v4__factory,
  Governance,
  GovernanceMock,
  GovernanceMock__factory,
  Governance__factory,
  USDC,
} from '../typechain-types';
import { deployContractsExceptCustodian, expect } from './helpers';

describe('Custodian', function () {
  let CustodianFactory: Custodian__factory;
  let GovernanceFactory: Governance__factory;
  let GovernanceMockFactory: GovernanceMock__factory;

  beforeEach(async () => {
    [CustodianFactory, GovernanceFactory, GovernanceMockFactory] =
      await Promise.all([
        ethers.getContractFactory('Custodian'),
        ethers.getContractFactory('Governance'),
        ethers.getContractFactory('GovernanceMock'),
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
        CustodianFactory.deploy(ethAddress, governance.address),
      ).to.eventually.be.rejectedWith(/invalid exchange contract address/i);
    });

    it('should revert for invalid governance address', async () => {
      await expect(
        CustodianFactory.deploy(exchange.address, ethAddress),
      ).to.eventually.be.rejectedWith(/invalid exchange contract address/i);
    });
  });

  describe('setExchange', () => {
    let custodian: Custodian;
    let Exchange_v4: Exchange_v4__factory;
    let governanceMock: GovernanceMock;
    let owner: SignerWithAddress;
    let usdc: USDC;

    beforeEach(async () => {
      [owner] = await ethers.getSigners();
      const results = await deployContractsExceptCustodian(owner);
      Exchange_v4 = results.Exchange_v4;
      usdc = results.usdc;
      governanceMock = await GovernanceMockFactory.deploy();
      custodian = await CustodianFactory.deploy(
        results.exchange.address,
        governanceMock.address,
      );
      governanceMock.setCustodian(custodian.address);
    });

    it('should work when sent from governance address', async () => {
      const newExchange = await Exchange_v4.deploy(
        ethers.constants.AddressZero,
        usdc.address,
        owner.address,
        owner.address,
        owner.address,
        [owner.address],
      );

      await governanceMock.setExchange(newExchange.address);

      expect(custodian.queryFilter(custodian.filters.ExchangeChanged()))
        .to.eventually.be.an('array')
        .with.lengthOf(2);
    });

    it('should revert for invalid address', async () => {
      await expect(
        governanceMock.setExchange(ethAddress),
      ).to.eventually.be.rejectedWith(/invalid contract address/i);
    });

    it('should revert for non-contract address', async () => {
      await expect(
        governanceMock.setExchange(owner.address),
      ).to.eventually.be.rejectedWith(/invalid contract address/i);
    });

    it('should revert when not sent from governance address', async () => {
      await expect(
        custodian
          .connect((await ethers.getSigners())[1])
          .setExchange(ethAddress),
      ).to.eventually.be.rejectedWith(/caller must be governance/i);
    });
  });

  describe('setGovernance', () => {
    let custodian: Custodian;
    let governanceMock: GovernanceMock;

    beforeEach(async () => {
      const [owner] = await ethers.getSigners();
      const results = await deployContractsExceptCustodian(owner);
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
  });
});
