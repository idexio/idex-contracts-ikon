/* Autogenerated file. Do not edit manually. */
/* tslint:disable */
/* eslint-disable */
import { Signer, utils, Contract, ContractFactory, Overrides } from "ethers";
import type { Provider, TransactionRequest } from "@ethersproject/providers";
import type { PromiseOrValue } from "../../../common";
import type {
  Constants,
  ConstantsInterface,
} from "../../../contracts/libraries/Constants";

const _abi = [
  {
    inputs: [],
    name: "basisPointsInTotal",
    outputs: [
      {
        internalType: "uint64",
        name: "",
        type: "uint64",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "depositIndexNotSet",
    outputs: [
      {
        internalType: "uint64",
        name: "",
        type: "uint64",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "maxChainPropagationPeriodInBlocks",
    outputs: [
      {
        internalType: "uint256",
        name: "",
        type: "uint256",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "maxDelegateKeyExpirationPeriodInMs",
    outputs: [
      {
        internalType: "uint256",
        name: "",
        type: "uint256",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "maxFeeBasisPoints",
    outputs: [
      {
        internalType: "uint64",
        name: "",
        type: "uint64",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "msInOneHour",
    outputs: [
      {
        internalType: "uint64",
        name: "",
        type: "uint64",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "pipPriceMultiplier",
    outputs: [
      {
        internalType: "uint64",
        name: "",
        type: "uint64",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "signatureHashVersion",
    outputs: [
      {
        internalType: "uint8",
        name: "",
        type: "uint8",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
];

const _bytecode =
  "0x61015f61003a600b82828239805160001a60731461002d57634e487b7160e01b600052600060045260246000fd5b30600052607381538281f3fe73000000000000000000000000000000000000000030146080604052600436106100925760003560e01c8063baa7771b11610065578063baa7771b146100eb578063d0469fb214610105578063dd94d1c914610114578063f4b0d1b81461011f57600080fd5b806355966a7c146100975780635f4f3d86146100be578063acfc2ab2146100c7578063b2e525b3146100e1575b600080fd5b6100a06107d081565b60405167ffffffffffffffff90911681526020015b60405180910390f35b6100a061271081565b6100d3640757b12c0081565b6040519081526020016100b5565b6100d36203138081565b6100f3600581565b60405160ff90911681526020016100b5565b6100a067ffffffffffffffff81565b6100a06305f5e10081565b6100a06236ee808156fea26469706673582212203ebc175eb8426d79d84047d2488c2feb4fb6844419639289e472b13fb007a86964736f6c634300080d0033";

type ConstantsConstructorParams =
  | [signer?: Signer]
  | ConstructorParameters<typeof ContractFactory>;

const isSuperArgs = (
  xs: ConstantsConstructorParams
): xs is ConstructorParameters<typeof ContractFactory> => xs.length > 1;

export class Constants__factory extends ContractFactory {
  constructor(...args: ConstantsConstructorParams) {
    if (isSuperArgs(args)) {
      super(...args);
    } else {
      super(_abi, _bytecode, args[0]);
    }
  }

  override deploy(
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<Constants> {
    return super.deploy(overrides || {}) as Promise<Constants>;
  }
  override getDeployTransaction(
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): TransactionRequest {
    return super.getDeployTransaction(overrides || {});
  }
  override attach(address: string): Constants {
    return super.attach(address) as Constants;
  }
  override connect(signer: Signer): Constants__factory {
    return super.connect(signer) as Constants__factory;
  }

  static readonly bytecode = _bytecode;
  static readonly abi = _abi;
  static createInterface(): ConstantsInterface {
    return new utils.Interface(_abi) as ConstantsInterface;
  }
  static connect(
    address: string,
    signerOrProvider: Signer | Provider
  ): Constants {
    return new Contract(address, _abi, signerOrProvider) as Constants;
  }
}
