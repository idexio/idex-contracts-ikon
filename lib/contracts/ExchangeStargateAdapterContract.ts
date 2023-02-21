import { ethers } from 'ethers';

import * as utils from './utils';
import BaseContract from './BaseContract';

import {
  ExchangeStargateAdapter,
  ExchangeStargateAdapter__factory,
} from '../../typechain-types';

export default class ExchangeStargateAdapterContract extends BaseContract<ExchangeStargateAdapter> {
  public constructor(address: string, signerWalletPrivateKey?: string) {
    super(
      ExchangeStargateAdapter__factory.connect(
        address,
        signerWalletPrivateKey
          ? new ethers.Wallet(signerWalletPrivateKey, utils.loadProvider())
          : utils.loadProvider(),
      ),
    );
  }

  public static async deploy(
    args: Parameters<ExchangeStargateAdapter__factory['deploy']>,
    ownerWalletPrivateKey: string,
  ): Promise<ExchangeStargateAdapterContract> {
    const owner = new ethers.Wallet(
      ownerWalletPrivateKey,
      utils.loadProvider(),
    );

    const contract = await new ExchangeStargateAdapter__factory(owner).deploy(
      ...args,
    );
    await contract.deployTransaction.wait();

    return new this(contract.address);
  }

  public getEthersContract(): ExchangeStargateAdapter {
    return this.contract;
  }
}
