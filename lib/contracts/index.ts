import fs from 'fs';
import path from 'path';
import { ethers } from 'ethers';

import { initRpcApi, loadProvider } from './utils';

import ChainlinkAggregator from './ChainlinkAggregator';
import CustodianContract from './CustodianContract';
import ExchangeContract from './ExchangeContract';
import GovernanceContract from './GovernanceContract';
import USDCContract from './USDCContract';

export {
  initRpcApi,
  loadProvider,
  ChainlinkAggregator,
  CustodianContract,
  ExchangeContract,
  GovernanceContract,
  USDCContract,
};

export type LibraryName =
  | 'Deleveraging'
  | 'Depositing'
  | 'Funding'
  | 'MarketAdmin'
  | 'NonceInvalidations'
  | 'NonMutatingMargin'
  | 'PositionBelowMinimumLiquidation'
  | 'PositionInDeactivatedMarketLiquidation'
  | 'Trading'
  | 'WalletLiquidation'
  | 'Withdrawing';

export async function deployLibrary(
  name: LibraryName,
  ownerWalletPrivateKey: string,
): Promise<string> {
  const bytecode = loadLibraryBytecode(name);
  const owner = new ethers.Wallet(ownerWalletPrivateKey, loadProvider());
  const library = await new ethers.ContractFactory(
    [],
    bytecode,
    owner,
  ).deploy();
  await library.deployTransaction.wait();

  return library.address;
}

const libraryNameToBytecodeMap = new Map<LibraryName, string>();

function loadLibraryBytecode(name: LibraryName): string {
  if (!libraryNameToBytecodeMap.has(name)) {
    const { bytecode } = JSON.parse(
      fs
        .readFileSync(
          path.join(
            __dirname,
            '..',
            '..',
            '..',
            'artifacts',
            'contracts',
            'libraries',
            `${name}.sol`,
            `${name}.json`,
          ),
        )
        .toString('utf8'),
    );
    libraryNameToBytecodeMap.set(name, bytecode);
  }
  return libraryNameToBytecodeMap.get(name) as string; // Will never be undefined as it gets set above
}
