import { ethers } from 'hardhat';
import { expect } from 'chai';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

import { Custodian__factory } from '../typechain-types';
import { ethAddress } from '../lib';

let Custodian: Custodian__factory;
beforeEach(async () => {
  Custodian = await ethers.getContractFactory('Custodian');
});

describe('Custodian', function () {
  describe('deploy', async function () {
    it('should work', async () => {
      const [ownerWallet] = await ethers.getSigners();
      const { exchange, governance } = await deployContracts(ownerWallet);
      await Custodian.deploy(exchange.address, governance.address);
    });

    it('should revert for invalid exchange address', async () => {
      const [owner] = await ethers.getSigners();
      const { governance } = await deployContracts(owner);

      let error;
      try {
        await Custodian.deploy(ethAddress, governance.address);
      } catch (e) {
        error = e;
      }
      expect(error).to.not.be.undefined;
      expect(error)
        .to.have.property('message')
        .to.match(/invalid exchange contract address/i);
    });

    it('should revert for invalid governance address', async () => {
      const [owner] = await ethers.getSigners();
      const { exchange } = await deployContracts(owner);

      let error;
      try {
        await Custodian.deploy(exchange.address, ethAddress);
      } catch (e) {
        error = e;
      }
      expect(error).to.not.be.undefined;
      expect(error)
        .to.have.property('message')
        .to.match(/invalid exchange contract address/i);
    });
  });
});

export async function deployContracts(
  owner: SignerWithAddress,
  exitFundWallet: SignerWithAddress = owner,
  feeWallet: SignerWithAddress = owner,
  insuranceFund: SignerWithAddress = owner,
  indexPriceCollectionServiceWallet: SignerWithAddress = owner,
) {
  const [
    AcquisitionDeleveraging,
    ClosureDeleveraging,
    Depositing,
    Funding,
    MarketAdmin,
    NonceInvalidations,
    NonMutatingMargin,
    PositionBelowMinimumLiquidation,
    PositionInDeactivatedMarketLiquidation,
    Trading,
    WalletLiquidation,
    Withdrawing,
  ] = await Promise.all([
    ethers.getContractFactory('AcquisitionDeleveraging'),
    ethers.getContractFactory('ClosureDeleveraging'),
    ethers.getContractFactory('Depositing'),
    ethers.getContractFactory('Funding'),
    ethers.getContractFactory('MarketAdmin'),
    ethers.getContractFactory('NonceInvalidations'),
    ethers.getContractFactory('NonMutatingMargin'),
    ethers.getContractFactory('PositionBelowMinimumLiquidation'),
    ethers.getContractFactory('PositionInDeactivatedMarketLiquidation'),
    ethers.getContractFactory('Trading'),
    ethers.getContractFactory('WalletLiquidation'),
    ethers.getContractFactory('Withdrawing'),
  ]);
  const [
    acquisitionDeleveraging,
    closureDeleveraging,
    depositing,
    funding,
    marketAdmin,
    nonceInvalidations,
    nonMutatingMargin,
    positionBelowMinimumLiquidation,
    positionInDeactivatedMarketLiquidation,
    trading,
    walletLiquidation,
    withdrawing,
  ] = await Promise.all([
    (await AcquisitionDeleveraging.deploy()).deployed(),
    (await ClosureDeleveraging.deploy()).deployed(),
    (await Depositing.deploy()).deployed(),
    (await Funding.deploy()).deployed(),
    (await MarketAdmin.deploy()).deployed(),
    (await NonceInvalidations.deploy()).deployed(),
    (await NonMutatingMargin.deploy()).deployed(),
    (await PositionBelowMinimumLiquidation.deploy()).deployed(),
    (await PositionInDeactivatedMarketLiquidation.deploy()).deployed(),
    (await Trading.deploy()).deployed(),
    (await WalletLiquidation.deploy()).deployed(),
    (await Withdrawing.deploy()).deployed(),
  ]);

  const [USDC, Exchange_v4, Governance] = await Promise.all([
    ethers.getContractFactory('USDC'),
    ethers.getContractFactory('Exchange_v4', {
      libraries: {
        AcquisitionDeleveraging: acquisitionDeleveraging.address,
        ClosureDeleveraging: closureDeleveraging.address,
        Depositing: depositing.address,
        Funding: funding.address,
        MarketAdmin: marketAdmin.address,
        NonceInvalidations: nonceInvalidations.address,
        NonMutatingMargin: nonMutatingMargin.address,
        PositionBelowMinimumLiquidation:
          positionBelowMinimumLiquidation.address,
        PositionInDeactivatedMarketLiquidation:
          positionInDeactivatedMarketLiquidation.address,
        Trading: trading.address,
        WalletLiquidation: walletLiquidation.address,
        Withdrawing: withdrawing.address,
      },
    }),
    ethers.getContractFactory('Governance'),
  ]);

  const usdc = await (await USDC.deploy()).deployed();

  const [exchange, governance] = await Promise.all([
    (
      await Exchange_v4.deploy(
        ethers.constants.AddressZero,
        usdc.address,
        exitFundWallet.address,
        feeWallet.address,
        insuranceFund.address,
        [indexPriceCollectionServiceWallet.address],
      )
    ).deployed(),
    (await Governance.deploy(0)).deployed(),
  ]);

  return { exchange, governance };
}
