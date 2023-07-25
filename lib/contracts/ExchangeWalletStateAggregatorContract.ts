import { ethers } from 'ethers';

import * as utils from './utils';
import BaseContract from './BaseContract';

import {
  ExchangeWalletStateAggregator,
  ExchangeWalletStateAggregator__factory,
} from '../../typechain-types';

export default class ExchangeWalletStateAggregatorContract extends BaseContract<ExchangeWalletStateAggregator> {
  public constructor(address: string, signerWalletPrivateKey?: string) {
    super(
      ExchangeWalletStateAggregator__factory.connect(
        address,
        signerWalletPrivateKey
          ? new ethers.Wallet(signerWalletPrivateKey, utils.loadProvider())
          : utils.loadProvider(),
      ),
    );
  }

  public static async deploy(
    args: Parameters<ExchangeWalletStateAggregator__factory['deploy']>,
    ownerWalletPrivateKey: string,
  ): Promise<ExchangeWalletStateAggregatorContract> {
    const owner = new ethers.Wallet(
      ownerWalletPrivateKey,
      utils.loadProvider(),
    );

    const contract = await new ExchangeWalletStateAggregator__factory(
      owner,
    ).deploy(...args);
    await contract.deployTransaction.wait();

    return new this(contract.address);
  }

  public getEthersContract(): ExchangeWalletStateAggregator {
    return this.contract;
  }
}
