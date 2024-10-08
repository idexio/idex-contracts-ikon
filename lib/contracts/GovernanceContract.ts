import { ethers } from 'ethers';

import * as utils from './utils';
import BaseContract from './BaseContract';

import { Governance, Governance__factory } from '../../typechain-types';

export default class GovernanceContract extends BaseContract<Governance> {
  public constructor(address: string, signerWalletPrivateKey?: string) {
    super(
      Governance__factory.connect(
        address,
        signerWalletPrivateKey
          ? new ethers.Wallet(signerWalletPrivateKey, utils.loadProvider())
          : utils.loadProvider(),
      ),
    );
  }

  public static async deploy(
    args: Parameters<Governance__factory['deploy']>,
    ownerWalletPrivateKey: string,
  ): Promise<GovernanceContract> {
    const owner = new ethers.Wallet(
      ownerWalletPrivateKey,
      utils.loadProvider(),
    );

    const contract = await new Governance__factory(owner).deploy(...args);

    return new this(await (await contract.waitForDeployment()).getAddress());
  }

  public getEthersContract(): Governance {
    return this.contract;
  }
}
