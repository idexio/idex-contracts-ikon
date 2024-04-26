import { ethers } from 'ethers';

import {
  ExchangeStargateV2Adapter__factory,
} from '../../typechain-types';

import BaseContract from './BaseContract';
import * as utils from './utils';

import type {
  ExchangeStargateV2Adapter} from '../../typechain-types';

export default class ExchangeStargateV2AdapterContract extends BaseContract<ExchangeStargateV2Adapter> {
  public constructor(address: string, signerWalletPrivateKey?: string) {
    super(
      ExchangeStargateV2Adapter__factory.connect(
        address,
        signerWalletPrivateKey
          ? new ethers.Wallet(signerWalletPrivateKey, utils.loadProvider())
          : utils.loadProvider(),
      ),
    );
  }

  public static async deploy(
    args: Parameters<ExchangeStargateV2Adapter__factory['deploy']>,
    ownerWalletPrivateKey: string,
  ): Promise<ExchangeStargateV2AdapterContract> {
    const owner = new ethers.Wallet(
      ownerWalletPrivateKey,
      utils.loadProvider(),
    );

    const contract = await new ExchangeStargateV2Adapter__factory(owner).deploy(
      ...args,
    );

    return new this(await (await contract.waitForDeployment()).getAddress());
  }

  public getEthersContract(): ExchangeStargateV2Adapter {
    return this.contract;
  }
}
