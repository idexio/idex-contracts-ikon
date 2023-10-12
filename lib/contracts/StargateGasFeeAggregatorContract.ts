import { ethers } from 'ethers';

import * as utils from './utils';
import BaseContract from './BaseContract';

import {
  StargateGasFeeAggregator,
  StargateGasFeeAggregator__factory,
} from '../../typechain-types';

export default class StargateGasFeeAggregatorContract extends BaseContract<StargateGasFeeAggregator> {
  public constructor(address: string, signerWalletPrivateKey?: string) {
    super(
      StargateGasFeeAggregator__factory.connect(
        address,
        signerWalletPrivateKey
          ? new ethers.Wallet(signerWalletPrivateKey, utils.loadProvider())
          : utils.loadProvider(),
      ),
    );
  }

  public static async deploy(
    args: Parameters<StargateGasFeeAggregator__factory['deploy']>,
    ownerWalletPrivateKey: string,
  ): Promise<StargateGasFeeAggregatorContract> {
    const owner = new ethers.Wallet(
      ownerWalletPrivateKey,
      utils.loadProvider(),
    );

    const contract = await new StargateGasFeeAggregator__factory(owner).deploy(
      ...args,
    );
    await contract.deployTransaction.wait();

    return new this(contract.address);
  }

  public getEthersContract(): StargateGasFeeAggregator {
    return this.contract;
  }
}
