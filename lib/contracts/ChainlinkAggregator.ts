import { ethers } from 'ethers';

import * as utils from './utils';
import BaseContract from './BaseContract';

import {
  ChainlinkAggregatorMock,
  ChainlinkAggregatorMock__factory,
} from '../../typechain-types';

export default class ChainlinkAggregatorMockContract extends BaseContract<ChainlinkAggregatorMock> {
  public constructor(address: string, signerWalletPrivateKey?: string) {
    super(
      ChainlinkAggregatorMock__factory.connect(
        address,
        signerWalletPrivateKey
          ? new ethers.Wallet(signerWalletPrivateKey, utils.loadProvider())
          : utils.loadProvider(),
      ),
    );
  }

  public static async deploy(
    args: Parameters<ChainlinkAggregatorMock__factory['deploy']>,
    ownerWalletPrivateKey: string,
  ): Promise<ChainlinkAggregatorMockContract> {
    const owner = new ethers.Wallet(
      ownerWalletPrivateKey,
      utils.loadProvider(),
    );

    const contract = await new ChainlinkAggregatorMock__factory(owner).deploy(
      ...args,
    );
    await contract.deployTransaction.wait();

    return new this(contract.address);
  }

  public getEthersContract(): ChainlinkAggregatorMock {
    return this.contract;
  }
}
