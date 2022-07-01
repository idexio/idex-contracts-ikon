/* Autogenerated file. Do not edit manually. */
/* tslint:disable */
/* eslint-disable */
import {
  Signer,
  utils,
  Contract,
  ContractFactory,
  BigNumberish,
  Overrides,
} from "ethers";
import type { Provider, TransactionRequest } from "@ethersproject/providers";
import type { PromiseOrValue } from "../../common";
import type {
  Governance,
  GovernanceInterface,
} from "../../contracts/Governance";

const _abi = [
  {
    inputs: [
      {
        internalType: "uint256",
        name: "blockDelay",
        type: "uint256",
      },
    ],
    stateMutability: "nonpayable",
    type: "constructor",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "address",
        name: "oldExchange",
        type: "address",
      },
      {
        indexed: false,
        internalType: "address",
        name: "newExchange",
        type: "address",
      },
    ],
    name: "ExchangeUpgradeCanceled",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "address",
        name: "oldExchange",
        type: "address",
      },
      {
        indexed: false,
        internalType: "address",
        name: "newExchange",
        type: "address",
      },
    ],
    name: "ExchangeUpgradeFinalized",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "address",
        name: "oldExchange",
        type: "address",
      },
      {
        indexed: false,
        internalType: "address",
        name: "newExchange",
        type: "address",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "blockThreshold",
        type: "uint256",
      },
    ],
    name: "ExchangeUpgradeInitiated",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "address",
        name: "oldGovernance",
        type: "address",
      },
      {
        indexed: false,
        internalType: "address",
        name: "newGovernance",
        type: "address",
      },
    ],
    name: "GovernanceUpgradeCanceled",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "address",
        name: "oldGovernance",
        type: "address",
      },
      {
        indexed: false,
        internalType: "address",
        name: "newGovernance",
        type: "address",
      },
    ],
    name: "GovernanceUpgradeFinalized",
    type: "event",
  },
  {
    anonymous: false,
    inputs: [
      {
        indexed: false,
        internalType: "address",
        name: "oldGovernance",
        type: "address",
      },
      {
        indexed: false,
        internalType: "address",
        name: "newGovernance",
        type: "address",
      },
      {
        indexed: false,
        internalType: "uint256",
        name: "blockThreshold",
        type: "uint256",
      },
    ],
    name: "GovernanceUpgradeInitiated",
    type: "event",
  },
  {
    inputs: [],
    name: "cancelExchangeUpgrade",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [],
    name: "cancelGovernanceUpgrade",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "newExchange",
        type: "address",
      },
    ],
    name: "finalizeExchangeUpgrade",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "newGovernance",
        type: "address",
      },
    ],
    name: "finalizeGovernanceUpgrade",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "newExchange",
        type: "address",
      },
    ],
    name: "initiateExchangeUpgrade",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "newGovernance",
        type: "address",
      },
    ],
    name: "initiateGovernanceUpgrade",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [],
    name: "removeAdmin",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "address",
        name: "newAdmin",
        type: "address",
      },
    ],
    name: "setAdmin",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        internalType: "contract ICustodian",
        name: "newCustodian",
        type: "address",
      },
    ],
    name: "setCustodian",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
];

const _bytecode =
  "0x60c060405234801561001057600080fd5b5060405161189938038061189983398101604081905261002f91610050565b336080819052600080546001600160a01b031916909117905560a052610069565b60006020828403121561006257600080fd5b5051919050565b60805160a0516117fd61009c6000396000818161055801526114050152600081816106ed0152610d9301526117fd6000f3fe608060405234801561001057600080fd5b50600436106100a35760003560e01c8063856bf4fb11610076578063a2bb645b1161005b578063a2bb645b14610106578063b48a25de14610119578063e72b81d31461012c57600080fd5b8063856bf4fb146100eb5780639a202d47146100fe57600080fd5b8063403f3731146100a85780636034c594146100bd578063704b6c02146100d057806379fbe988146100e3575b600080fd5b6100bb6100b6366004611747565b610134565b005b6100bb6100cb366004611747565b6102b1565b6100bb6100de366004611747565b6106d5565b6100bb610894565b6100bb6100f9366004611747565b610a64565b6100bb610d7b565b6100bb610114366004611747565b610e2a565b6100bb610127366004611747565b61115f565b6100bb61157c565b60005473ffffffffffffffffffffffffffffffffffffffff1633146101a05760405162461bcd60e51b815260206004820152601460248201527f43616c6c6572206d7573742062652061646d696e00000000000000000000000060448201526064015b60405180910390fd5b60015473ffffffffffffffffffffffffffffffffffffffff16156102065760405162461bcd60e51b815260206004820152601e60248201527f437573746f6469616e2063616e206f6e6c7920626520736574206f6e636500006044820152606401610197565b73ffffffffffffffffffffffffffffffffffffffff81163b61026a5760405162461bcd60e51b815260206004820152600f60248201527f496e76616c6964206164647265737300000000000000000000000000000000006044820152606401610197565b600180547fffffffffffffffffffffffff00000000000000000000000000000000000000001673ffffffffffffffffffffffffffffffffffffffff92909216919091179055565b60005473ffffffffffffffffffffffffffffffffffffffff1633146103185760405162461bcd60e51b815260206004820152601460248201527f43616c6c6572206d7573742062652061646d696e0000000000000000000000006044820152606401610197565b73ffffffffffffffffffffffffffffffffffffffff81163b61037c5760405162461bcd60e51b815260206004820152600f60248201527f496e76616c6964206164647265737300000000000000000000000000000000006044820152606401610197565b600160009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff166376a162a36040518163ffffffff1660e01b8152600401602060405180830381865afa1580156103e9573d6000803e3d6000fd5b505050506040513d601f19601f8201168201806040525081019061040d919061176b565b73ffffffffffffffffffffffffffffffffffffffff168173ffffffffffffffffffffffffffffffffffffffff16036104ad5760405162461bcd60e51b815260206004820152602960248201527f4d75737420626520646966666572656e742066726f6d2063757272656e74204760448201527f6f7665726e616e636500000000000000000000000000000000000000000000006064820152608401610197565b60045460ff16156105265760405162461bcd60e51b815260206004820152602660248201527f476f7665726e616e6365207570677261646520616c726561647920696e20707260448201527f6f677265737300000000000000000000000000000000000000000000000000006064820152608401610197565b604080516060810182526001815273ffffffffffffffffffffffffffffffffffffffff8316602082015290810161057d7f000000000000000000000000000000000000000000000000000000000000000043611788565b90528051600480546020808501517fffffffffffffffffffffff0000000000000000000000000000000000000000009092169315157fffffffffffffffffffffff0000000000000000000000000000000000000000ff169390931761010073ffffffffffffffffffffffffffffffffffffffff9283160217825560409384015160055560015484517f76a162a300000000000000000000000000000000000000000000000000000000815294517fa6a21646d34d1f976c739d43e6cc7ba4789033bbf2000f2da2159648ff856f869591909216936376a162a3938281019391928290030181865afa158015610676573d6000803e3d6000fd5b505050506040513d601f19601f8201168201806040525081019061069a919061176b565b6005546040805173ffffffffffffffffffffffffffffffffffffffff938416815292851660208401528201526060015b60405180910390a150565b3373ffffffffffffffffffffffffffffffffffffffff7f0000000000000000000000000000000000000000000000000000000000000000161461075a5760405162461bcd60e51b815260206004820152601460248201527f43616c6c6572206d757374206265206f776e65720000000000000000000000006044820152606401610197565b73ffffffffffffffffffffffffffffffffffffffff81166107bd5760405162461bcd60e51b815260206004820152601660248201527f496e76616c69642077616c6c65742061646472657373000000000000000000006044820152606401610197565b60005473ffffffffffffffffffffffffffffffffffffffff9081169082160361084d5760405162461bcd60e51b8152602060048201526024808201527f4d75737420626520646966666572656e742066726f6d2063757272656e74206160448201527f646d696e000000000000000000000000000000000000000000000000000000006064820152608401610197565b600080547fffffffffffffffffffffffff00000000000000000000000000000000000000001673ffffffffffffffffffffffffffffffffffffffff92909216919091179055565b60005473ffffffffffffffffffffffffffffffffffffffff1633146108fb5760405162461bcd60e51b815260206004820152601460248201527f43616c6c6572206d7573742062652061646d696e0000000000000000000000006044820152606401610197565b60025460ff1661094d5760405162461bcd60e51b815260206004820152601f60248201527f4e6f2045786368616e6765207570677261646520696e2070726f6772657373006044820152606401610197565b600280547fffffffffffffffffffffff00000000000000000000000000000000000000000081169091556000600355600154604080517f3bffd49d000000000000000000000000000000000000000000000000000000008152905173ffffffffffffffffffffffffffffffffffffffff6101009094048416937f3deda624693a0f1dbb15e39d11fa8a129b906e05a75c7083f6182a1f50ad90e6931691633bffd49d9160048083019260209291908290030181865afa158015610a14573d6000803e3d6000fd5b505050506040513d601f19601f82011682018060405250810190610a38919061176b565b6040805173ffffffffffffffffffffffffffffffffffffffff92831681529184166020830152016106ca565b60005473ffffffffffffffffffffffffffffffffffffffff163314610acb5760405162461bcd60e51b815260206004820152601460248201527f43616c6c6572206d7573742062652061646d696e0000000000000000000000006044820152606401610197565b60025460ff16610b1d5760405162461bcd60e51b815260206004820152601f60248201527f4e6f2045786368616e6765207570677261646520696e2070726f6772657373006044820152606401610197565b60025473ffffffffffffffffffffffffffffffffffffffff8281166101009092041614610b8c5760405162461bcd60e51b815260206004820152601060248201527f41646472657373206d69736d61746368000000000000000000000000000000006044820152606401610197565b600354431015610bde5760405162461bcd60e51b815260206004820152601f60248201527f426c6f636b207468726573686f6c64206e6f74207965742072656163686564006044820152606401610197565b600154604080517f3bffd49d000000000000000000000000000000000000000000000000000000008152905160009273ffffffffffffffffffffffffffffffffffffffff1691633bffd49d9160048083019260209291908290030181865afa158015610c4e573d6000803e3d6000fd5b505050506040513d601f19601f82011682018060405250810190610c72919061176b565b6001546040517f67b1f5df00000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff85811660048301529293509116906367b1f5df90602401600060405180830381600087803b158015610ce157600080fd5b505af1158015610cf5573d6000803e3d6000fd5b5050600280547fffffffffffffffffffffff000000000000000000000000000000000000000000169055505060006003556040805173ffffffffffffffffffffffffffffffffffffffff8084168252841660208201527f9bf4f59f92728f201976543c65ca8488ac780cd0b6164d6b5954caea89db9ca191015b60405180910390a15050565b3373ffffffffffffffffffffffffffffffffffffffff7f00000000000000000000000000000000000000000000000000000000000000001614610e005760405162461bcd60e51b815260206004820152601460248201527f43616c6c6572206d757374206265206f776e65720000000000000000000000006044820152606401610197565b600080547fffffffffffffffffffffffff0000000000000000000000000000000000000000169055565b60005473ffffffffffffffffffffffffffffffffffffffff163314610e915760405162461bcd60e51b815260206004820152601460248201527f43616c6c6572206d7573742062652061646d696e0000000000000000000000006044820152606401610197565b60045460ff16610f095760405162461bcd60e51b815260206004820152602160248201527f4e6f20476f7665726e616e6365207570677261646520696e2070726f6772657360448201527f73000000000000000000000000000000000000000000000000000000000000006064820152608401610197565b60045473ffffffffffffffffffffffffffffffffffffffff8281166101009092041614610f785760405162461bcd60e51b815260206004820152601060248201527f41646472657373206d69736d61746368000000000000000000000000000000006044820152606401610197565b600554431015610fca5760405162461bcd60e51b815260206004820152601f60248201527f426c6f636b207468726573686f6c64206e6f74207965742072656163686564006044820152606401610197565b600154604080517f76a162a3000000000000000000000000000000000000000000000000000000008152905160009273ffffffffffffffffffffffffffffffffffffffff16916376a162a39160048083019260209291908290030181865afa15801561103a573d6000803e3d6000fd5b505050506040513d601f19601f8201168201806040525081019061105e919061176b565b6001546040517fab033ea900000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff858116600483015292935091169063ab033ea990602401600060405180830381600087803b1580156110cd57600080fd5b505af11580156110e1573d6000803e3d6000fd5b5050600480547fffffffffffffffffffffff000000000000000000000000000000000000000000169055505060006005556040805173ffffffffffffffffffffffffffffffffffffffff8084168252841660208201527fe8e9795e6f99fe9438deb950156dc5163addbc22868f205864db35ce0369a2469101610d6f565b60005473ffffffffffffffffffffffffffffffffffffffff1633146111c65760405162461bcd60e51b815260206004820152601460248201527f43616c6c6572206d7573742062652061646d696e0000000000000000000000006044820152606401610197565b73ffffffffffffffffffffffffffffffffffffffff81163b61122a5760405162461bcd60e51b815260206004820152600f60248201527f496e76616c6964206164647265737300000000000000000000000000000000006044820152606401610197565b600160009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16633bffd49d6040518163ffffffff1660e01b8152600401602060405180830381865afa158015611297573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906112bb919061176b565b73ffffffffffffffffffffffffffffffffffffffff168173ffffffffffffffffffffffffffffffffffffffff160361135b5760405162461bcd60e51b815260206004820152602760248201527f4d75737420626520646966666572656e742066726f6d2063757272656e74204560448201527f786368616e6765000000000000000000000000000000000000000000000000006064820152608401610197565b60025460ff16156113d35760405162461bcd60e51b8152602060048201526024808201527f45786368616e6765207570677261646520616c726561647920696e2070726f6760448201527f72657373000000000000000000000000000000000000000000000000000000006064820152608401610197565b604080516060810182526001815273ffffffffffffffffffffffffffffffffffffffff8316602082015290810161142a7f000000000000000000000000000000000000000000000000000000000000000043611788565b90528051600280546020808501517fffffffffffffffffffffff0000000000000000000000000000000000000000009092169315157fffffffffffffffffffffff0000000000000000000000000000000000000000ff169390931761010073ffffffffffffffffffffffffffffffffffffffff928316021790915560409283015160035560015483517f3bffd49d00000000000000000000000000000000000000000000000000000000815293517f23d35db20b045836aab7d18a2c24bf69897923223ead5f6f155d855c08d56b50949190921692633bffd49d926004808401938290030181865afa158015611524573d6000803e3d6000fd5b505050506040513d601f19601f82011682018060405250810190611548919061176b565b6003546040805173ffffffffffffffffffffffffffffffffffffffff938416815292851660208401528201526060016106ca565b60005473ffffffffffffffffffffffffffffffffffffffff1633146115e35760405162461bcd60e51b815260206004820152601460248201527f43616c6c6572206d7573742062652061646d696e0000000000000000000000006044820152606401610197565b60045460ff1661165b5760405162461bcd60e51b815260206004820152602160248201527f4e6f20476f7665726e616e6365207570677261646520696e2070726f6772657360448201527f73000000000000000000000000000000000000000000000000000000000000006064820152608401610197565b600480547fffffffffffffffffffffff000000000000000000000000000000000000000000811682556000600555600154604080517f76a162a3000000000000000000000000000000000000000000000000000000008152905173ffffffffffffffffffffffffffffffffffffffff6101009094048416947f9add6141586291375a36aaa907814cda80daf2b740e0ba60d92ff52024a2aa4a9493909316926376a162a3928082019260209290918290030181865afa158015610a14573d6000803e3d6000fd5b73ffffffffffffffffffffffffffffffffffffffff8116811461174457600080fd5b50565b60006020828403121561175957600080fd5b813561176481611722565b9392505050565b60006020828403121561177d57600080fd5b815161176481611722565b600082198211156117c2577f4e487b7100000000000000000000000000000000000000000000000000000000600052601160045260246000fd5b50019056fea264697066735822122009d84048aef0c6ea61788a32093f88da7925fe8431e64af33029d9fd8c879cd864736f6c634300080f0033";

type GovernanceConstructorParams =
  | [signer?: Signer]
  | ConstructorParameters<typeof ContractFactory>;

const isSuperArgs = (
  xs: GovernanceConstructorParams
): xs is ConstructorParameters<typeof ContractFactory> => xs.length > 1;

export class Governance__factory extends ContractFactory {
  constructor(...args: GovernanceConstructorParams) {
    if (isSuperArgs(args)) {
      super(...args);
    } else {
      super(_abi, _bytecode, args[0]);
    }
  }

  override deploy(
    blockDelay: PromiseOrValue<BigNumberish>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): Promise<Governance> {
    return super.deploy(blockDelay, overrides || {}) as Promise<Governance>;
  }
  override getDeployTransaction(
    blockDelay: PromiseOrValue<BigNumberish>,
    overrides?: Overrides & { from?: PromiseOrValue<string> }
  ): TransactionRequest {
    return super.getDeployTransaction(blockDelay, overrides || {});
  }
  override attach(address: string): Governance {
    return super.attach(address) as Governance;
  }
  override connect(signer: Signer): Governance__factory {
    return super.connect(signer) as Governance__factory;
  }

  static readonly bytecode = _bytecode;
  static readonly abi = _abi;
  static createInterface(): GovernanceInterface {
    return new utils.Interface(_abi) as GovernanceInterface;
  }
  static connect(
    address: string,
    signerOrProvider: Signer | Provider
  ): Governance {
    return new Contract(address, _abi, signerOrProvider) as Governance;
  }
}