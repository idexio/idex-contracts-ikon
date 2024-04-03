import { ethers } from 'ethers';

import * as utils from './utils';
import BaseContract from './BaseContract';

import {
  PythOraclePriceAdapter,
  PythOraclePriceAdapter__factory,
} from '../../typechain-types';

export default class PythOraclePriceAdapterContract extends BaseContract<PythOraclePriceAdapter> {
  public constructor(address: string, signerWalletPrivateKey?: string) {
    super(
      PythOraclePriceAdapter__factory.connect(
        address,
        signerWalletPrivateKey
          ? new ethers.Wallet(signerWalletPrivateKey, utils.loadProvider())
          : utils.loadProvider(),
      ),
    );
  }

  public static async deploy(
    args: Parameters<PythOraclePriceAdapter__factory['deploy']>,
    ownerWalletPrivateKey: string,
  ): Promise<PythOraclePriceAdapterContract> {
    const owner = new ethers.Wallet(
      ownerWalletPrivateKey,
      utils.loadProvider(),
    );

    const contract = await new PythOraclePriceAdapter__factory(owner).deploy(
      ...args,
    );

    return new this(await (await contract.waitForDeployment()).getAddress());
  }

  public getEthersContract(): PythOraclePriceAdapter {
    return this.contract;
  }
}
