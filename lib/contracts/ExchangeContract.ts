import { ethers } from 'ethers';

import * as utils from './utils';
import BaseContract from './BaseContract';

import { ExchangeV4, ExchangeV4__factory } from '../../typechain';

export default class ExchangeContract extends BaseContract<ExchangeV4> {
  public constructor(address: string, signerWalletPrivateKey?: string) {
    super(
      ExchangeV4__factory.connect(
        address,
        signerWalletPrivateKey
          ? new ethers.Wallet(signerWalletPrivateKey, utils.loadProvider())
          : utils.loadProvider(),
      ),
    );
  }

  public static async deploy(
    args: Parameters<ExchangeV4__factory['deploy']>,
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
      typeof ExchangeV4__factory
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

    const contract = await new ExchangeV4__factory(
      linkLibraryAddresses,
      owner,
    ).deploy(...args);
    await contract.deployTransaction.wait();

    return new this(contract.address);
  }
}
