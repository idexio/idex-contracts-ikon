import { ethers } from 'ethers';

import * as utils from './utils';
import BaseContract from './BaseContract';

import { Exchange_v4, Exchange_v4__factory } from '../../typechain-types';

export default class ExchangeContract extends BaseContract<Exchange_v4> {
  public constructor(address: string, signerWalletPrivateKey?: string) {
    super(
      Exchange_v4__factory.connect(
        address,
        signerWalletPrivateKey
          ? new ethers.Wallet(signerWalletPrivateKey, utils.loadProvider())
          : utils.loadProvider(),
      ),
    );
  }

  public static async deploy(
    args: Parameters<Exchange_v4__factory['deploy']>,
    libraryAddresses: {
      acquisitionDeleveraging: string;
      closureDeleveraging: string;
      depositing: string;
      funding: string;
      insuranceFundWalletUpgrade: string;
      marketAdmin: string;
      nonceInvalidations: string;
      nonMutatingMargin: string;
      positionBelowMinimumLiquidation: string;
      positionInDeactivatedMarketLiquidation: string;
      trading: string;
      walletLiquidation: string;
      withdrawing: string;
    },
    ownerWalletPrivateKey: string,
  ): Promise<ExchangeContract> {
    const linkLibraryAddresses: ConstructorParameters<
      typeof Exchange_v4__factory
    >[0] = {
      ['contracts/libraries/AcquisitionDeleveraging.sol:AcquisitionDeleveraging']:
        libraryAddresses.acquisitionDeleveraging,
      ['contracts/libraries/ClosureDeleveraging.sol:ClosureDeleveraging']:
        libraryAddresses.closureDeleveraging,
      ['contracts/libraries/Depositing.sol:Depositing']:
        libraryAddresses.depositing,
      ['contracts/libraries/Funding.sol:Funding']: libraryAddresses.funding,
      ['contracts/libraries/InsuranceFundWalletUpgrade.sol:InsuranceFundWalletUpgrade']:
        libraryAddresses.insuranceFundWalletUpgrade,
      ['contracts/libraries/MarketAdmin.sol:MarketAdmin']:
        libraryAddresses.marketAdmin,
      ['contracts/libraries/NonceInvalidations.sol:NonceInvalidations']:
        libraryAddresses.nonceInvalidations,
      ['contracts/libraries/NonMutatingMargin.sol:NonMutatingMargin']:
        libraryAddresses.nonMutatingMargin,
      ['contracts/libraries/PositionBelowMinimumLiquidation.sol:PositionBelowMinimumLiquidation']:
        libraryAddresses.positionBelowMinimumLiquidation,
      ['contracts/libraries/PositionInDeactivatedMarketLiquidation.sol:PositionInDeactivatedMarketLiquidation']:
        libraryAddresses.positionInDeactivatedMarketLiquidation,
      ['contracts/libraries/Trading.sol:Trading']: libraryAddresses.trading,
      ['contracts/libraries/WalletLiquidation.sol:WalletLiquidation']:
        libraryAddresses.walletLiquidation,
      ['contracts/libraries/Withdrawing.sol:Withdrawing']:
        libraryAddresses.withdrawing,
    };

    const owner = new ethers.Wallet(
      ownerWalletPrivateKey,
      utils.loadProvider(),
    );

    const contract = await new Exchange_v4__factory(
      linkLibraryAddresses,
      owner,
    ).deploy(...args);
    await contract.deployTransaction.wait();

    return new this(contract.address);
  }

  public getEthersContract(): Exchange_v4 {
    return this.contract;
  }
}
