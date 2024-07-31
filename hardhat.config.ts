import * as dotenv from 'dotenv';

import '@typechain/hardhat';
import '@nomicfoundation/hardhat-ethers';
import '@nomicfoundation/hardhat-chai-matchers';
import '@nomicfoundation/hardhat-verify';
import 'hardhat-contract-sizer';
import 'solidity-coverage';
import type { HardhatUserConfig } from 'hardhat/config';

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

const SOLC_VERSION = '0.8.18';

const SOLC_VERSION_STARGATE = '0.8.25';

// Solidity coverage tool does not support the viaIR compiler option
// https://github.com/sc-forks/solidity-coverage/issues/715
const solidity = process.env.COVERAGE
  ? {
      compilers: [
        {
          version: SOLC_VERSION,
          settings: {
            optimizer: {
              enabled: true,
              runs: 1,
            },
          },
        },
        {
          version: SOLC_VERSION_STARGATE,
          settings: {
            optimizer: {
              enabled: true,
              runs: 1,
            },
          },
        },
      ],
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
        {
          version: SOLC_VERSION_STARGATE,
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
        'contracts/bridge-adapters/ExchangeStargateV2Adapter.sol': {
          version: SOLC_VERSION_STARGATE,
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
    arbitrumSepolia: {
      chainId: 421614,
      url: 'https://sepolia-rollup.arbitrum.io/rpc',
    },
    xchain: {
      chainId: 94524,
      url: 'https://xchain-rpc.idex.io',
    },
    xchainTestnet: {
      chainId: 64002,
      url: 'https://xchain-testnet-rpc.idex.io/',
    },
    polygonAmoy: {
      chainId: 80002,
      url: 'https://rpc-amoy.polygon.technology',
    },
    polygonMumbai: {
      chainId: 80001,
      url: 'https://polygon-mumbai.infura.io/v3/f893932c1fc54aa592bbe1b7419c8761',
    },
    polygonMainnet: {
      chainId: 137,
      url: 'https://polygon-mainnet.infura.io/v3/8a369d58e1a54e22a71b559a2aa92001',
    },
  },
  etherscan: {
    apiKey: {
      private: 'abc',
      arbitrumSepolia: 'H6U42K28KCMQ2NRFXFE28I9UCP5HYV6M8U',
      xchain: 'abc',
      xchainTestnet: 'abc',
      polygonAmoy: 'bad22612-5107-4e49-b6d9-861b9f613cd5',
      polygonMumbai: 'K7QYKN8XKGTR5J3W6D8A7625N7CH5RWITF',
      polygonMainnet: 'K7QYKN8XKGTR5J3W6D8A7625N7CH5RWITF',
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
        network: 'xchain',
        chainId: 94524,
        urls: {
          apiURL: 'https://xchain-explorer.idex.io/api/v1',
          browserURL: 'https://xchain-explorer.idex.io/',
        },
      },
      {
        network: 'xchainTestnet',
        chainId: 64002,
        urls: {
          apiURL: 'https://xchain-testnet-explorer.idex.io/api/v1',
          browserURL: 'https://xchain-testnet-explorer.idex.io/',
        },
      },
      {
        network: 'arbitrumSepolia',
        chainId: 421614,
        urls: {
          apiURL: 'https://api-sepolia.arbiscan.io/api',
          browserURL: 'https://sepolia.arbiscan.io/',
        },
      },
      {
        network: 'polygonAmoy',
        chainId: 80002,
        urls: {
          apiURL:
            'https://www.oklink.com/api/explorer/v1/contract/verify/async/api/amoy',
          browserURL: 'https://www.oklink.com/amoy',
        },
      },
      {
        network: 'polygonMumbai',
        chainId: 80001,
        urls: {
          apiURL: 'https://api-testnet.polygonscan.com/api',
          browserURL: 'https://mumbai.polygonscan.com/',
        },
      },
      {
        network: 'polygonMainnet',
        chainId: 137,
        urls: {
          apiURL: 'https://api.polygonscan.com/api',
          browserURL: 'https://polygonscan.com/',
        },
      },
    ],
  },
};

export default config;
