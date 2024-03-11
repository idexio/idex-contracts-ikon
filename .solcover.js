module.exports = {
  configureYulOptimizer: true,
  istanbulReporter: ['json-summary', 'html', 'text'],
  mocha: {
    enableTimeouts: false,
  },
  matrixOutputPath: './coverage/testMatrix.json',
  mochaJsonOutputPath: './coverage/mochaOutput.json',
  skipFiles: [
    'bridge-adapters/ExchangeStargateAdapter.sol',
    'test/OraclePriceAdapterMock.sol',
    'test/StargateRouterMock.sol',
    'util/ExchangeWalletStateAggregator.sol',
  ],
  solcOptimizerDetails: {
    peephole: false,
    inliner: false,
    jumpdestRemover: false,
    orderLiterals: true, // <-- TRUE! Stack too deep when false
    deduplicate: false,
    cse: false,
    constantOptimizer: false,
    yul: false,
  },
};
