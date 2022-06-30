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
      depositing: string;
      nonceInvalidations: string;
      perpetual: string;
      trading: string;
      withdrawing: string;
    },
    ownerWalletPrivateKey: string,
  ): Promise<ExchangeContract> {
    const linkLibraryAddresses: ConstructorParameters<
      typeof Exchange_v4__factory
    >[0] = {
      ['contracts/libraries/Depositing.sol:Depositing']:
        libraryAddresses.depositing,
      ['contracts/libraries/NonceInvalidations.sol:NonceInvalidations']:
        libraryAddresses.nonceInvalidations,
      ['contracts/libraries/Perpetual.sol:Perpetual']:
        libraryAddresses.perpetual,
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
}
