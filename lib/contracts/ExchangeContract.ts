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
      liquidation: string;
      margin: string;
      marketAdmin: string;
      nonceInvalidations: string;
      trading: string;
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
      ['contracts/libraries/Liquidation.sol:Liquidation']:
        libraryAddresses.liquidation,
      ['contracts/libraries/Margin.sol:Margin']: libraryAddresses.margin,
      ['contracts/libraries/MarketAdmin.sol:MarketAdmin']:
        libraryAddresses.marketAdmin,
      ['contracts/libraries/NonceInvalidations.sol:NonceInvalidations']:
        libraryAddresses.nonceInvalidations,
      ['contracts/libraries/Trading.sol:Trading']: libraryAddresses.trading,
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
