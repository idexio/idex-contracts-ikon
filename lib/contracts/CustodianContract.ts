import { ethers } from 'ethers';

import * as utils from './utils';
import BaseContract from './BaseContract';

import { Custodian, Custodian__factory } from '../../typechain';

export default class CustodianContract extends BaseContract<Custodian> {
  public constructor(address: string, signerWalletPrivateKey?: string) {
    super(
      Custodian__factory.connect(
        address,
        signerWalletPrivateKey
          ? new ethers.Wallet(signerWalletPrivateKey, utils.loadProvider())
          : utils.loadProvider(),
      ),
    );
  }

  public static async deploy(
    args: Parameters<Custodian__factory['deploy']>,
    ownerWalletPrivateKey: string,
  ): Promise<CustodianContract> {
    const owner = new ethers.Wallet(
      ownerWalletPrivateKey,
      utils.loadProvider(),
    );

    const contract = await new Custodian__factory(owner).deploy(...args);
    await contract.deployTransaction.wait();

    return new this(contract.address);
  }
}
