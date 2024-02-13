import { ethers } from 'ethers';

import * as utils from './utils';
import BaseContract from './BaseContract';

import {
  PythIndexPriceAdapter,
  PythIndexPriceAdapter__factory,
} from '../../typechain-types';

export default class PythIndexPriceAdapterContract extends BaseContract<PythIndexPriceAdapter> {
  public constructor(address: string, signerWalletPrivateKey?: string) {
    super(
      PythIndexPriceAdapter__factory.connect(
        address,
        signerWalletPrivateKey
          ? new ethers.Wallet(signerWalletPrivateKey, utils.loadProvider())
          : utils.loadProvider(),
      ),
    );
  }

  public static async deploy(
    args: Parameters<PythIndexPriceAdapter__factory['deploy']>,
    ownerWalletPrivateKey: string,
  ): Promise<PythIndexPriceAdapterContract> {
    const owner = new ethers.Wallet(
      ownerWalletPrivateKey,
      utils.loadProvider(),
    );

    const contract = await new PythIndexPriceAdapter__factory(owner).deploy(
      ...args,
    );

    return new this(await (await contract.waitForDeployment()).getAddress());
  }

  public getEthersContract(): PythIndexPriceAdapter {
    return this.contract;
  }
}
