module.exports = {
  istanbulReporter: ['json-summary', 'html', 'text'],
  mocha: {
    enableTimeouts: false,
  },
  matrixOutputPath: './coverage/testMatrix.json',
  mochaJsonOutputPath: './coverage/mochaOutput.json',
  skipFiles: [
    'bridge-adapters/ExchangeStargateAdapter.sol',
    'bridge-adapters/ExchangeStargateV2Adapter.sol',
    'test/OraclePriceAdapterMock.sol',
    'test/StargateRouterMock.sol',
    'test/StargateV2PoolMock.sol',
    'util/ExchangeWalletStateAggregator.sol',
  ],
};
