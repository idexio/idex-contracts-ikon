import { ethers } from 'ethers';

export default abstract class BaseContract<
  Contract extends ethers.BaseContract,
> {
  protected readonly contract: Contract;

  protected constructor(contract: Contract) {
    this.contract = contract;
  }

  public async getAddress(): Promise<string> {
    return this.contract.getAddress();
  }
}
