import { ethers } from 'ethers';

import * as utils from './utils';
import BaseContract from './BaseContract';

import {
  ChainlinkAggregator,
  ChainlinkAggregator__factory,
} from '../../typechain-types';

export default class ChainlinkAggregatorContract extends BaseContract<ChainlinkAggregator> {
  public constructor(address: string, signerWalletPrivateKey?: string) {
    super(
      ChainlinkAggregator__factory.connect(
        address,
        signerWalletPrivateKey
          ? new ethers.Wallet(signerWalletPrivateKey, utils.loadProvider())
          : utils.loadProvider(),
      ),
    );
  }

  public static async deploy(
    args: Parameters<ChainlinkAggregator__factory['deploy']>,
    ownerWalletPrivateKey: string,
  ): Promise<ChainlinkAggregatorContract> {
    const owner = new ethers.Wallet(
      ownerWalletPrivateKey,
      utils.loadProvider(),
    );

    const contract = await new ChainlinkAggregator__factory(owner).deploy(
      ...args,
    );
    await contract.deployTransaction.wait();

    return new this(contract.address);
  }

  public getEthersContract(): ChainlinkAggregator {
    return this.contract;
  }
}
