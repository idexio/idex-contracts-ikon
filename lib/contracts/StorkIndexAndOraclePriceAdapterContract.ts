import { ethers } from 'ethers';

import * as utils from './utils';
import BaseContract from './BaseContract';

import {
  StorkIndexAndOraclePriceAdapter,
  StorkIndexAndOraclePriceAdapter__factory,
} from '../../typechain-types';

export default class StorkIndexAndOraclePriceAdapterContract extends BaseContract<StorkIndexAndOraclePriceAdapter> {
  public constructor(address: string, signerWalletPrivateKey?: string) {
    super(
      StorkIndexAndOraclePriceAdapter__factory.connect(
        address,
        signerWalletPrivateKey
          ? new ethers.Wallet(signerWalletPrivateKey, utils.loadProvider())
          : utils.loadProvider(),
      ),
    );
  }

  public static async deploy(
    args: Parameters<StorkIndexAndOraclePriceAdapter__factory['deploy']>,
    ownerWalletPrivateKey: string,
  ): Promise<StorkIndexAndOraclePriceAdapterContract> {
    const owner = new ethers.Wallet(
      ownerWalletPrivateKey,
      utils.loadProvider(),
    );

    const contract = await new StorkIndexAndOraclePriceAdapter__factory(
      owner,
    ).deploy(...args);
    await contract.deployTransaction.wait();

    return new this(contract.address);
  }

  public getEthersContract(): StorkIndexAndOraclePriceAdapter {
    return this.contract;
  }
}
