import { ethers } from 'ethers';

import * as utils from './utils';
import BaseContract from './BaseContract';

import {
  StargateFeeAggregator,
  StargateFeeAggregator__factory,
} from '../../typechain-types';

export default class StargateFeeAggregatorContract extends BaseContract<StargateFeeAggregator> {
  public constructor(address: string, signerWalletPrivateKey?: string) {
    super(
      StargateFeeAggregator__factory.connect(
        address,
        signerWalletPrivateKey
          ? new ethers.Wallet(signerWalletPrivateKey, utils.loadProvider())
          : utils.loadProvider(),
      ),
    );
  }

  public static async deploy(
    args: Parameters<StargateFeeAggregator__factory['deploy']>,
    ownerWalletPrivateKey: string,
  ): Promise<StargateFeeAggregatorContract> {
    const owner = new ethers.Wallet(
      ownerWalletPrivateKey,
      utils.loadProvider(),
    );

    const contract = await new StargateFeeAggregator__factory(owner).deploy(
      ...args,
    );
    await contract.deployTransaction.wait();

    return new this(contract.address);
  }

  public getEthersContract(): StargateFeeAggregator {
    return this.contract;
  }
}
