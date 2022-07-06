import { ethers } from 'ethers';

import * as utils from './utils';
import BaseContract from './BaseContract';

import { USDC, USDC__factory } from '../../typechain-types';

export default class USDCContract extends BaseContract<USDC> {
  public constructor(address: string, signerWalletPrivateKey?: string) {
    super(
      USDC__factory.connect(
        address,
        signerWalletPrivateKey
          ? new ethers.Wallet(signerWalletPrivateKey, utils.loadProvider())
          : utils.loadProvider(),
      ),
    );
  }

  public static async deploy(
    args: Parameters<USDC__factory['deploy']>,
    ownerWalletPrivateKey: string,
  ): Promise<USDCContract> {
    const owner = new ethers.Wallet(
      ownerWalletPrivateKey,
      utils.loadProvider(),
    );

    const contract = await new USDC__factory(owner).deploy(...args);
    await contract.deployTransaction.wait();

    return new this(contract.address);
  }
}
