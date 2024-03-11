import * as dotenv from 'dotenv';

import '@nomiclabs/hardhat-etherscan';
import '@nomiclabs/hardhat-waffle';
import '@typechain/hardhat';
import 'hardhat-contract-sizer';
import 'hardhat-gas-reporter';
import 'solidity-coverage';
import { HardhatUserConfig } from 'hardhat/config';

/*
import * as path from 'path';
import { TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS } from 'hardhat/builtin-tasks/task-names';

subtask(
  TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS,
  async (_, { config }, runSuper) => {
    const paths = await runSuper();

    return paths.filter((solidityFilePath) => {
      const relativePath = path.relative(
        config.paths.sources,
        solidityFilePath,
      );

      return relativePath === 'Exchange.sol';
    });
  },
);
*/

dotenv.config();

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more

const SOLC_VERSION = '0.8.18' as const;

// Solidity coverage tool does not support the viaIR compiler option
// https://github.com/sc-forks/solidity-coverage/issues/715
const solidity = process.env.COVERAGE
  ? {
      version: SOLC_VERSION,
      settings: {
        optimizer: {
          enabled: true,
          runs: 1,
        },
      },
    }
  : {
      compilers: [
        {
          version: SOLC_VERSION,
          settings: {
            optimizer: {
              enabled: true,
              runs: 1000000,
            },
            viaIR: true,
          },
        },
      ],
      overrides: {
        'contracts/Exchange.sol': {
          version: SOLC_VERSION,
          settings: {
            optimizer: {
              enabled: true,
              runs: 100,
            },
            viaIR: true,
          },
        },
      },
    };

const config: HardhatUserConfig = {
  solidity,
  mocha: {
    timeout: 100000000,
  },
  networks: {
    hardhat: {
      allowUnlimitedContractSize: !!process.env.COVERAGE,
    },
    private: {
      chainId: 1001,
      url: 'https://rpc-dev-geth.idex-dev.com:8545',
    },
    zkevm: {
      chainId: 23432,
      url: 'https://rpc-devnet-idex.hardfork.dev',
    },
  },
  etherscan: {
    apiKey: {
      private: 'abc',
      zkevm: 'abc',
    },
    customChains: [
      {
        network: 'private',
        chainId: 1001,
        urls: {
          apiURL: 'https://explorer-dev-geth.idex-dev.com/api/v1',
          browserURL: 'https://explorer-dev-geth.idex-dev.com/',
        },
      },
      {
        network: 'zkevm',
        chainId: 23432,
        urls: {
          apiURL: 'https://explorer-staging-zkevm.idex-dev.com/api/v1',
          browserURL: 'https://explorer-staging-zkevm.idex-dev.com/',
        },
      },
    ],
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency: 'USD',
  },
};

export default config;
