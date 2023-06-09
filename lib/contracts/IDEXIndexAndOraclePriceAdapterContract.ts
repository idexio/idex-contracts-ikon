import { ethers } from 'ethers';

import * as utils from './utils';
import BaseContract from './BaseContract';

import {
  IDEXIndexAndOraclePriceAdapter,
  IDEXIndexAndOraclePriceAdapter__factory,
} from '../../typechain-types';

export default class IDEXIndexAndOraclePriceAdapterContract extends BaseContract<IDEXIndexAndOraclePriceAdapter> {
  public constructor(address: string, signerWalletPrivateKey?: string) {
    super(
      IDEXIndexAndOraclePriceAdapter__factory.connect(
        address,
        signerWalletPrivateKey
          ? new ethers.Wallet(signerWalletPrivateKey, utils.loadProvider())
          : utils.loadProvider(),
      ),
    );
  }

  public static async deploy(
    args: Parameters<IDEXIndexAndOraclePriceAdapter__factory['deploy']>,
    ownerWalletPrivateKey: string,
  ): Promise<IDEXIndexAndOraclePriceAdapterContract> {
    const owner = new ethers.Wallet(
      ownerWalletPrivateKey,
      utils.loadProvider(),
    );

    const contract = await new IDEXIndexAndOraclePriceAdapter__factory(
      owner,
    ).deploy(...args);
    await contract.deployTransaction.wait();

    return new this(contract.address);
  }

  public getEthersContract(): IDEXIndexAndOraclePriceAdapter {
    return this.contract;
  }
}
