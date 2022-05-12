// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.13;

import { Address } from '@openzeppelin/contracts/utils/Address.sol';

import { AssetUnitConversions } from './libraries/AssetUnitConversions.sol';
import { BalanceTracking } from './libraries/BalanceTracking.sol';
import { Constants } from './libraries/Constants.sol';
import { Depositing } from './libraries/Depositing.sol';
import { NonceInvalidation, Withdrawal } from './libraries/Structs.sol';
import { NonceInvalidations } from './libraries/NonceInvalidations.sol';
import { OrderSide } from './libraries/Enums.sol';
import { Owned } from './Owned.sol';
import { Trading } from './libraries/Trading.sol';
import { Validations } from './libraries/Validations.sol';
import { Withdrawing } from './libraries/Withdrawing.sol';
import { ICustodian, IExchange } from './libraries/Interfaces.sol';
import { Market, OraclePrice, Order, OrderBookTrade, Withdrawal } from './libraries/Structs.sol';

contract Exchange_v4 is IExchange, Owned {
  using BalanceTracking for BalanceTracking.Storage;
  using NonceInvalidations for mapping(address => NonceInvalidation);

  // Events //

  /**
   * @notice Emitted when a user deposits collateral tokens with `deposit`
   */
  event Deposited(
    uint64 index,
    address wallet,
    uint64 quantityInPips,
    int64 newExchangeBalanceInPips
  );
  /**
   * @notice Emitted when the Dispatcher Wallet submits a trade for execution with
   * `executeOrderBookTrade`
   */
  event OrderBookTradeExecuted(
    address buyWallet,
    address sellWallet,
    string baseAssetSymbol,
    string quoteAssetSymbol,
    uint64 baseQuantityInPips,
    uint64 quoteQuantityInPips,
    OrderSide takerSide
  );
  /**
   * @notice Emitted when the Dispatcher Wallet submits a withdrawal with `withdraw`
   */
  event Withdrawn(
    address wallet,
    uint64 quantityInPips,
    int64 newExchangeBalanceInPips
  );

  // Internally used structs //

  struct WalletExit {
    bool exists;
    uint256 effectiveBlockNumber;
  }

  // Storage //

  // Balance tracking
  BalanceTracking.Storage _balanceTracking;
  // CLOB - mapping of order wallet hash => isComplete
  mapping(bytes32 => bool) _completedOrderHashes;
  // Withdrawals - mapping of withdrawal wallet hash => isComplete
  mapping(bytes32 => bool) _completedWithdrawalHashes;
  // Custodian
  ICustodian _custodian;
  // Deposit index
  uint64 public _depositIndex;
  // If positive (index increases) longs pay shorts; if negative (index decreases) shorts pay longs
  mapping(string => int64[]) _fundingMultipliersByBaseAssetSymbol;
  // Milliseconds since epoch, always aligned to hour
  mapping(string => uint64) _lastFundingRatePublishTimestampInMsByBaseAssetSymbol;
  // All markets TODO Enablement
  Market[] public _markets;
  // Markets mapped by symbol TODO Enablement
  mapping(string => Market) _marketsBySymbol;
  // TODO Upgrade through Governance
  address _oracleWalletAddress;
  // CLOB - mapping of wallet => last invalidated timestampInMs
  mapping(address => NonceInvalidation) _nonceInvalidations;
  // CLOB - mapping of order hash => filled quantity in pips
  mapping(bytes32 => uint64) _partiallyFilledOrderQuantitiesInPips;
  // Exits
  mapping(address => WalletExit) public _walletExits;

  address immutable _collateralAssetAddress;
  string _collateralAssetSymbol;
  uint8 immutable _collateralAssetDecimals;

  // Tunable parameters
  uint256 _chainPropagationPeriod;
  address _dispatcherWallet;
  address _feeWallet;

  /**
   * @notice Instantiate a new `Exchange` contract
   *
   * @dev Sets `_balanceTracking.migrationSource` to first argument, and `_owner` and `_admin` to
   * `msg.sender`
   */
  constructor(
    IExchange balanceMigrationSource,
    address collateralAssetAddress,
    string memory collateralAssetSymbol,
    uint8 collateralAssetDecimals,
    address feeWallet,
    address oracleWalletAddress
  ) Owned() {
    require(
      address(balanceMigrationSource) == address(0x0) ||
        Address.isContract(address(balanceMigrationSource)),
      'Invalid migration source'
    );
    _balanceTracking.migrationSource = balanceMigrationSource;

    require(
      Address.isContract(address(collateralAssetAddress)),
      'Invalid collateral asset address'
    );
    _collateralAssetAddress = collateralAssetAddress;
    _collateralAssetSymbol = collateralAssetSymbol;
    _collateralAssetDecimals = collateralAssetDecimals;

    setFeeWallet(feeWallet);

    require(
      address(oracleWalletAddress) != address(0x0),
      'Invalid oracle wallet'
    );
    _oracleWalletAddress = oracleWalletAddress;

    // Deposits must be manually enabled via `setDepositIndex`
    _depositIndex = Constants.depositIndexNotSet;
  }

  /**
   * @notice Sets the address of the `Custodian` contract
   *
   * @dev The `Custodian` accepts `Exchange` and `Governance` addresses in its constructor, after
   * which they can only be changed by the `Governance` contract itself. Therefore the `Custodian`
   * must be deployed last and its address set here on an existing `Exchange` contract. This value
   * is immutable once set and cannot be changed again
   *
   * @param newCustodian The address of the `Custodian` contract deployed against this `Exchange`
   * contract's address
   */
  function setCustodian(ICustodian newCustodian) external onlyAdmin {
    require(
      _custodian == ICustodian(payable(address(0x0))),
      'Custodian can only be set once'
    );
    require(Address.isContract(address(newCustodian)), 'Invalid address');

    _custodian = newCustodian;
  }

  /**
   * @notice Enable depositing assets into the Exchange by setting the current deposit index from
   * the old Exchange contract's value. This function can only be called once
   *
   */
  function setDepositIndex() external onlyAdmin {
    require(
      _depositIndex == Constants.depositIndexNotSet,
      'Can only be set once'
    );

    _depositIndex = address(_balanceTracking.migrationSource) == address(0x0)
      ? 0
      : _balanceTracking.migrationSource._depositIndex();
  }

  /**
   * @notice Sets the address of the Fee wallet
   *
   * @dev Trade and Withdraw fees will accrue in the `_balances` mappings for this wallet
   * @dev Visibility public instead of external to allow invocation from `constructor`
   *
   * @param newFeeWallet The new Fee wallet. Must be different from the current one
   */
  function setFeeWallet(address newFeeWallet) public onlyAdmin {
    require(newFeeWallet != address(0x0), 'Invalid wallet address');
    require(newFeeWallet != _feeWallet, 'Must be different from current');

    _feeWallet = newFeeWallet;
  }

  /**
   * @notice Load a wallet's balance by asset symbol, in pips
   *
   * @param wallet The wallet address to load the balance for. Can be different from `msg.sender`
   * @param assetSymbol The asset symbol to load the wallet's balance for
   *
   * @return The quantity denominated in pips of asset at `assetSymbol` currently deposited by
   * `wallet`
   */
  function loadBalanceInPipsBySymbol(
    address wallet,
    string calldata assetSymbol
  ) external view override returns (int64) {
    return
      _balanceTracking.loadBalanceInPipsFromMigrationSourceIfNeeded(
        wallet,
        assetSymbol
      );
  }

  /**
   * @notice Load the address of the Custodian contract
   *
   * @return The address of the Custodian contract
   */
  function loadCustodian() external view override returns (ICustodian) {
    return _custodian;
  }

  /**
   * @notice Load the address of the Fee wallet
   *
   * @return The address of the Fee wallet
   */
  function loadFeeWallet() external view returns (address) {
    return _feeWallet;
  }

  /**
   * @notice Load the quantity filled so far for a partially filled orders
   *
   * @dev Invalidating an order nonce will not clear partial fill quantities for earlier orders
   * because
   * the gas cost would potentially be unbound
   *
   * @param orderHash The order hash as originally signed by placing wallet that uniquely
   * identifies an order
   *
   * @return For partially filled orders, the amount filled so far in pips. For orders in all other
   * states, 0
   */
  function loadPartiallyFilledOrderQuantityInPips(bytes32 orderHash)
    external
    view
    returns (uint64)
  {
    return _partiallyFilledOrderQuantitiesInPips[orderHash];
  }

  // Dispatcher whitelisting //

  /**
   * @notice Sets the wallet whitelisted to dispatch transactions calling the
   * `executeOrderBookTrade`, `executePoolTrade`, `executeHybridTrade`, `withdraw`,
   * `executeAddLiquidity`, and `executeRemoveLiquidity` functions
   *
   * @param newDispatcherWallet The new whitelisted dispatcher wallet. Must be different from the
   * current one
   */
  function setDispatcher(address newDispatcherWallet) external onlyAdmin {
    require(newDispatcherWallet != address(0x0), 'Invalid wallet address');
    require(
      newDispatcherWallet != _dispatcherWallet,
      'Must be different from current'
    );
    _dispatcherWallet = newDispatcherWallet;
  }

  /**
   * @notice Clears the currently set whitelisted dispatcher wallet, effectively disabling calling
   * the `executeOrderBookTrade`, `executePoolTrade`, `executeHybridTrade`, `withdraw`,
   * `executeAddLiquidity`, and `executeRemoveLiquidity` functions until a new wallet is set with
   * `setDispatcher`
   */
  function removeDispatcher() external onlyAdmin {
    _dispatcherWallet = address(0x0);
  }

  modifier onlyDispatcher() {
    require(msg.sender == _dispatcherWallet, 'Caller is not dispatcher');
    _;
  }

  // Depositing //

  /**
   * @notice Deposit collateral token
   *
   * @param quantityInAssetUnits The quantity to deposit. The sending wallet must first call the
   * `approve` method on the token contract for at least this quantity first
   */
  function deposit(uint256 quantityInAssetUnits) external {
    // Deposits are disabled until `setDepositIndex` is called successfully
    require(_depositIndex != Constants.depositIndexNotSet, 'Deposits disabled');

    // Calling exitWallet disables deposits immediately on mining, in contrast to withdrawals and
    // trades which respect the Chain Propagation Period given by `effectiveBlockNumber` via
    // `isWalletExitFinalized`
    require(!_walletExits[msg.sender].exists, 'Wallet exited');

    (uint64 quantityInPips, int64 newExchangeBalanceInPips) = Depositing
      .deposit(
        msg.sender,
        quantityInAssetUnits,
        _collateralAssetAddress,
        _collateralAssetSymbol,
        _collateralAssetDecimals,
        _custodian,
        _balanceTracking
      );

    _depositIndex++;

    emit Deposited(
      _depositIndex,
      msg.sender,
      quantityInPips,
      newExchangeBalanceInPips
    );
  }

  // Trades //

  /**
   * @notice Settles a trade between two orders submitted and matched off-chain
   *
   * @param buy An `Order` struct encoding the parameters of the buy-side order (receiving base,
   * giving quote)
   * @param sell An `Order` struct encoding the parameters of the sell-side order (giving base,
   * receiving quote)
   * @param orderBookTrade An `OrderBookTrade` struct encoding the parameters of this trade
   * execution of the two orders
   */
  function executeOrderBookTrade(
    Order memory buy,
    Order memory sell,
    OrderBookTrade memory orderBookTrade
  ) external onlyDispatcher {
    require(
      !isWalletExitFinalized(buy.walletAddress),
      'Buy wallet exit finalized'
    );
    require(
      !isWalletExitFinalized(sell.walletAddress),
      'Sell wallet exit finalized'
    );

    Trading.executeOrderBookTrade(
      buy,
      sell,
      orderBookTrade,
      _feeWallet,
      _balanceTracking,
      _collateralAssetSymbol,
      _completedOrderHashes,
      _marketsBySymbol,
      _nonceInvalidations,
      _partiallyFilledOrderQuantitiesInPips
    );

    emit OrderBookTradeExecuted(
      buy.walletAddress,
      sell.walletAddress,
      orderBookTrade.baseAssetSymbol,
      orderBookTrade.quoteAssetSymbol,
      orderBookTrade.baseQuantityInPips,
      orderBookTrade.quoteQuantityInPips,
      orderBookTrade.makerSide == OrderSide.Buy ? OrderSide.Sell : OrderSide.Buy
    );
  }

  // Withdrawing //

  /**
   * @notice Settles a user withdrawal submitted off-chain. Calls restricted to currently
   * whitelisted Dispatcher wallet
   *
   * @param withdrawal A `Withdrawal` struct encoding the parameters of the withdrawal
   */
  function withdraw(Withdrawal memory withdrawal) public onlyDispatcher {
    require(!isWalletExitFinalized(withdrawal.walletAddress), 'Wallet exited');

    int64 newExchangeBalanceInPips = Withdrawing.withdraw(
      withdrawal,
      _collateralAssetAddress,
      _collateralAssetSymbol,
      _collateralAssetDecimals,
      _custodian,
      _feeWallet,
      _balanceTracking,
      _completedWithdrawalHashes
    );

    emit Withdrawn(
      withdrawal.walletAddress,
      withdrawal.grossQuantityInPips,
      newExchangeBalanceInPips
    );
  }

  // Market management //

  function addMarket(
    string calldata baseAssetSymbol,
    uint64 initialMarginFractionInBasisPoints,
    uint64 maintenanceMarginFractionInBasisPoints,
    uint64 incrementalInitialMarginFractionInBasisPoints,
    uint64 baselinePositionSizeInPips,
    uint64 incrementalPositionSizeInPips,
    uint64 maximumPositionSizeInPips
  ) external onlyAdmin {
    require(
      _markets.length < Constants.maxMarketCount,
      'Max market count reached'
    );
    require(!_marketsBySymbol[baseAssetSymbol].exists, 'Market already exists');

    Market memory market = Market({
      exists: true,
      baseAssetSymbol: baseAssetSymbol,
      initialMarginFractionInBasisPoints: initialMarginFractionInBasisPoints,
      maintenanceMarginFractionInBasisPoints: maintenanceMarginFractionInBasisPoints,
      incrementalInitialMarginFractionInBasisPoints: incrementalInitialMarginFractionInBasisPoints,
      baselinePositionSizeInPips: baselinePositionSizeInPips,
      incrementalPositionSizeInPips: incrementalPositionSizeInPips,
      maximumPositionSizeInPips: maximumPositionSizeInPips
    });

    _markets.push(market);
    _marketsBySymbol[market.baseAssetSymbol] = market;
  }

  // Oracle price feed //

  /** @notice Validates oracle signature. Validates oracleTimestampInMs is exactly one hour after
   * _lastFundingRatePublishTimestampInMs. Pushes fundingRate × oraclePrice to
   * _fundingMultipliersByBaseAssetAddress
   */
  function publishFundingMutipliers(OraclePrice[] calldata oraclePrices)
    external
  {
    for (uint8 i = 0; i < oraclePrices.length; i++) {
      OraclePrice memory oraclePrice = oraclePrices[i];

      Validations.validateOraclePriceSignature(
        oraclePrice,
        _oracleWalletAddress
      );

      uint64 lastPublishTimestampInMs = _lastFundingRatePublishTimestampInMsByBaseAssetSymbol[
          oraclePrice.baseAssetSymbol
        ];
      require(
        lastPublishTimestampInMs > 0
          ? lastPublishTimestampInMs + Constants.msInOneHour ==
            oraclePrice.timestampInMs
          : oraclePrice.timestampInMs % Constants.msInOneHour == 0,
        'Input price not hour-aligned'
      );

      // TODO Cleanup typecasts
      _fundingMultipliersByBaseAssetSymbol[oraclePrice.baseAssetSymbol].push(
        int64(
          (int256(
            uint256(
              AssetUnitConversions.assetUnitsToPips(
                oraclePrice.priceInAssetUnits,
                _collateralAssetDecimals
              )
            )
          ) * int256(oraclePrice.fundingRateInPips))
        )
      );
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol[
        oraclePrice.baseAssetSymbol
      ] = oraclePrice.timestampInMs;
    }
  }

  // True-ups base position funding debits/credits by walking all funding multipliers published
  // since last position update
  function updateAccountFunding(address wallet) external {
    int64 fundingInPips;

    for (uint8 marketIndex = 0; marketIndex < _markets.length; marketIndex++) {
      Market memory market = _markets[marketIndex];
      BalanceTracking.Balance storage basePosition = _balanceTracking
        .loadBalanceAndMigrateIfNeeded(wallet, market.baseAssetSymbol);

      (
        int64[] storage fundingMultipliers,
        uint64 lastFundingMultiplierTimestampInMs
      ) = (
          _fundingMultipliersByBaseAssetSymbol[market.baseAssetSymbol],
          _lastFundingRatePublishTimestampInMsByBaseAssetSymbol[
            market.baseAssetSymbol
          ]
        );

      if (
        basePosition.balanceInPips > 0 &&
        basePosition.updatedTimestampInMs < lastFundingMultiplierTimestampInMs
      ) {
        uint256 hoursSinceLastUpdate = (lastFundingMultiplierTimestampInMs -
          basePosition.updatedTimestampInMs) / Constants.msInOneHour;

        for (
          uint256 multiplierIndex = fundingMultipliers.length -
            hoursSinceLastUpdate;
          multiplierIndex < fundingMultipliers.length;
          multiplierIndex++
        ) {
          fundingInPips +=
            fundingMultipliers[multiplierIndex] *
            basePosition.balanceInPips;
        }

        basePosition.updatedTimestampInMs = lastFundingMultiplierTimestampInMs;
      }
    }

    BalanceTracking.Balance storage collateralBalance = _balanceTracking
      .loadBalanceAndMigrateIfNeeded(wallet, _collateralAssetSymbol);
    collateralBalance.balanceInPips += fundingInPips;
  }

  // Wallet exits //

  function isWalletExitFinalized(address wallet) internal view returns (bool) {
    WalletExit storage exit = _walletExits[wallet];
    return exit.exists && exit.effectiveBlockNumber <= block.number;
  }
}
