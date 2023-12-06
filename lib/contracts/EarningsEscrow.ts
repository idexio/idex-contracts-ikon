import { ethers } from 'ethers';

import * as utils from './utils';
import BaseContract from './BaseContract';

import { EarningsEscrow, EarningsEscrow__factory } from '../../typechain-types';

export default class EarningsEscrowContract extends BaseContract<EarningsEscrow> {
  public constructor(address: string, signerWalletPrivateKey?: string) {
    super(
      EarningsEscrow__factory.connect(
        address,
        signerWalletPrivateKey
          ? new ethers.Wallet(signerWalletPrivateKey, utils.loadProvider())
          : utils.loadProvider(),
      ),
    );
  }

  public static async deploy(
    args: Parameters<EarningsEscrow__factory['deploy']>,
    ownerWalletPrivateKey: string,
  ): Promise<EarningsEscrowContract> {
    const owner = new ethers.Wallet(
      ownerWalletPrivateKey,
      utils.loadProvider(),
    );

    const contract = await new EarningsEscrow__factory(owner).deploy(...args);

    return new this(await (await contract.waitForDeployment()).getAddress());
  }

  public getEthersContract(): EarningsEscrow {
    return this.contract;
  }
}
