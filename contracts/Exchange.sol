// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { Address } from '@openzeppelin/contracts/utils/Address.sol';
import { AssetUnitConversions } from './libraries/AssetUnitConversions.sol';
import { BalanceTracking } from './libraries/BalanceTracking.sol';
import { Constants } from './libraries/Constants.sol';
import { Deleveraging } from './libraries/Deleveraging.sol';
import { Depositing } from './libraries/Depositing.sol';
import { Hashing } from './libraries/Hashing.sol';
import { Liquidation } from './libraries/Liquidation.sol';
import { Margin } from './libraries/Margin.sol';
import { MarketAdmin } from './libraries/MarketAdmin.sol';
import { NonceInvalidations } from './libraries/NonceInvalidations.sol';
import { Owned } from './Owned.sol';
import { Perpetual } from './libraries/Perpetual.sol';
import { String } from './libraries/String.sol';
import { Trading } from './libraries/Trading.sol';
import { Withdrawing } from './libraries/Withdrawing.sol';
import { Balance, ExecuteOrderBookTradeArguments, FundingMultiplierQuartet, Market, OraclePrice, Order, OrderBookTrade, Withdrawal } from './libraries/Structs.sol';
import { DeleverageType, LiquidationType, OrderSide } from './libraries/Enums.sol';
import { ICustodian, IExchange } from './libraries/Interfaces.sol';
import { NonceInvalidation, Withdrawal } from './libraries/Structs.sol';

contract Exchange_v4 is IExchange, Owned {
  using BalanceTracking for BalanceTracking.Storage;
  using NonceInvalidations for mapping(address => NonceInvalidation);

  // Events //

  /**
   * @notice Emitted when an admin changes the Chain Propagation Period tunable parameter with
   * `setChainPropagationPeriod`
   */
  event ChainPropagationPeriodChanged(uint256 previousValue, uint256 newValue);
  /**
   * @notice Emitted when an admin changes the Delegate Key Expiration Period tunable parameter with
   * `setDelegateKeyExpirationPeriod`
   */
  event DelegateKeyExpirationPeriodChanged(
    uint256 previousValue,
    uint256 newValue
  );
  /**
   * @notice Emitted when an admin changes the position below minimum liquidation price tolerance tunable parameter
   * with `setPositionBelowMinimumLiquidationPriceToleranceBasisPoints`
   */
  event PositionBelowMinimumLiquidationPriceToleranceChanged(
    uint256 previousValue,
    uint256 newValue
  );
  /**
   * @notice Emitted when a user deposits quote tokens with `deposit`
   */
  event Deposited(
    uint64 index,
    address wallet,
    uint64 quantityInPips,
    int64 newExchangeBalanceInPips
  );
  /**
   * @notice Emitted when a user invokes the Exit Wallet mechanism with `exitWallet`
   */
  event WalletExited(address wallet, uint256 effectiveBlockNumber);
  /**
   * @notice Emitted when a user withdraws an asset balance through the Exit Wallet mechanism with
   * `withdrawExit`
   */
  event WalletExitWithdrawn(address wallet, uint64 quantityInPips);
  /**
   * @notice Emitted when a user clears the exited status of a wallet previously exited with
   * `exitWallet`
   */
  event WalletExitCleared(address wallet);
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
   * @notice Emitted when a user invalidates an order nonce with `invalidateOrderNonce`
   */
  event OrderNonceInvalidated(
    address wallet,
    uint128 nonce,
    uint128 timestampInMs,
    uint256 effectiveBlockNumber
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
  // Mapping of wallet => list of base asset symbols with open positions
  mapping(address => string[])
    public _baseAssetSymbolsWithOpenPositionsByWallet;
  // CLOB - mapping of order wallet hash => isComplete
  mapping(bytes32 => bool) _completedOrderHashes;
  // Withdrawals - mapping of withdrawal wallet hash => isComplete
  mapping(bytes32 => bool) _completedWithdrawalHashes;
  // Custodian
  ICustodian _custodian;
  // Deposit index
  uint64 public _depositIndex;
  // TODO Upgrade through Governance
  address _exitFundWallet;
  // If positive (index increases) longs pay shorts; if negative (index decreases) shorts pay longs
  mapping(string => FundingMultiplierQuartet[]) _fundingMultipliersByBaseAssetSymbol;
  // TODO Upgrade through Governance
  address _insuranceFundWallet;
  // Milliseconds since epoch, always aligned to hour
  mapping(string => uint64) _lastFundingRatePublishTimestampInMsByBaseAssetSymbol;
  // Markets mapped by symbol TODO Enablement
  mapping(string => mapping(address => Market)) _marketOverridesByBaseAssetSymbolAndWallet;
  // Markets mapped by symbol TODO Enablement
  mapping(string => Market) _marketsByBaseAssetSymbol;
  // TODO Upgrade through Governance
  address _oracleWallet;
  // CLOB - mapping of wallet => last invalidated timestampInMs
  mapping(address => NonceInvalidation) _nonceInvalidationsByWallet;
  // CLOB - mapping of order hash => filled quantity in pips
  mapping(bytes32 => uint64) _partiallyFilledOrderQuantitiesInPips;
  // Exits
  mapping(address => WalletExit) public _walletExits;

  address immutable _quoteAssetAddress;
  string _quoteAssetSymbol;
  uint8 immutable _quoteAssetDecimals;

  // Tunable parameters
  uint256 _chainPropagationPeriodInBlocks;
  uint64 _delegateKeyExpirationPeriodInMs;
  uint64 _positionBelowMinimumLiquidationPriceToleranceBasisPoints;
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
    address quoteAssetAddress,
    string memory quoteAssetSymbol,
    uint8 quoteAssetDecimals,
    address exitFundWallet,
    address feeWallet,
    address insuranceFundWallet,
    address oracleWallet
  ) Owned() {
    require(
      address(balanceMigrationSource) == address(0x0) ||
        Address.isContract(address(balanceMigrationSource)),
      'Invalid migration source'
    );
    _balanceTracking.migrationSource = balanceMigrationSource;

    require(
      Address.isContract(address(quoteAssetAddress)),
      'Invalid quote asset address'
    );
    _quoteAssetAddress = quoteAssetAddress;
    _quoteAssetSymbol = quoteAssetSymbol;
    _quoteAssetDecimals = quoteAssetDecimals;

    setFeeWallet(feeWallet);

    require(
      address(exitFundWallet) != address(0x0),
      'Invalid exit fund wallet'
    );
    _exitFundWallet = exitFundWallet;

    require(
      address(insuranceFundWallet) != address(0x0),
      'Invalid insurance wallet'
    );
    _insuranceFundWallet = insuranceFundWallet;

    require(address(oracleWallet) != address(0x0), 'Invalid oracle wallet');
    _oracleWallet = oracleWallet;

    // Deposits must be manually enabled via `setDepositIndex`
    _depositIndex = Constants.depositIndexNotSet;
  }

  // Tunable parameters //

  /**
   * @notice Sets a new Chain Propagation Period - the block delay after which order nonce invalidations
   * are respected by `executeTrade` and wallet exits are respected by `executeTrade` and `withdraw`
   *
   * @param newChainPropagationPeriodInBlocks The new Chain Propagation Period expressed as a number of blocks. Must
   * be less than `Constants.maxChainPropagationPeriodInBlocks`
   */
  function setChainPropagationPeriod(uint256 newChainPropagationPeriodInBlocks)
    external
    onlyAdmin
  {
    require(
      newChainPropagationPeriodInBlocks <
        Constants.maxChainPropagationPeriodInBlocks,
      'Must be less than 1 week'
    );

    uint256 oldChainPropagationPeriodInBlocks = _chainPropagationPeriodInBlocks;
    _chainPropagationPeriodInBlocks = newChainPropagationPeriodInBlocks;

    emit ChainPropagationPeriodChanged(
      oldChainPropagationPeriodInBlocks,
      newChainPropagationPeriodInBlocks
    );
  }

  /**
   * @notice Sets a new Delegate Key Expiration Period - the delay following a delegated key's nonce timestamp after
   * which it cannot be used to sign orders
   *
   * @param newDelegateKeyExpirationPeriodInMs The new Delegate Key Expiration Period expressed as milliseconds. Must
   * be less than `Constants.maxDelegateKeyExpirationPeriodInMs`
   */
  function setDelegateKeyExpirationPeriod(
    uint64 newDelegateKeyExpirationPeriodInMs
  ) external onlyAdmin {
    require(
      newDelegateKeyExpirationPeriodInMs <
        Constants.maxDelegateKeyExpirationPeriodInMs,
      'Must be less than 1 week'
    );

    uint64 oldDelegateKeyExpirationPeriodInMs = _delegateKeyExpirationPeriodInMs;
    _delegateKeyExpirationPeriodInMs = newDelegateKeyExpirationPeriodInMs;

    emit DelegateKeyExpirationPeriodChanged(
      oldDelegateKeyExpirationPeriodInMs,
      newDelegateKeyExpirationPeriodInMs
    );
  }

  /**
   * @notice Sets a new position below minimum liquidation price tolerance
   *
   * @param newPositionBelowMinimumLiquidationPriceToleranceBasisPoints The new position below minimum liquidation price tolerance
   * expressed as basis points. Must be less than `Constants.maxFeeBasisPoints`
   */
  function setPositionBelowMinimumLiquidationPriceToleranceBasisPoints(
    uint64 newPositionBelowMinimumLiquidationPriceToleranceBasisPoints
  ) external onlyAdmin {
    // TODO Do we want a separate constant cap for this?
    require(
      newPositionBelowMinimumLiquidationPriceToleranceBasisPoints <
        Constants.maxFeeBasisPoints,
      'Must be less than 20 percent'
    );

    uint64 oldPositionBelowMinimumLiquidationPriceToleranceBasisPoints = _positionBelowMinimumLiquidationPriceToleranceBasisPoints;
    _positionBelowMinimumLiquidationPriceToleranceBasisPoints = newPositionBelowMinimumLiquidationPriceToleranceBasisPoints;

    emit PositionBelowMinimumLiquidationPriceToleranceChanged(
      oldPositionBelowMinimumLiquidationPriceToleranceBasisPoints,
      newPositionBelowMinimumLiquidationPriceToleranceBasisPoints
    );
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
   * @notice Load a wallet's balance-tracking struct by asset symbol
   *
   * @param wallet The wallet address to load the balance for. Can be different from `msg.sender`
   * @param assetSymbol The asset symbol to load the wallet's balance for
   *
   * @return The internal `Balance` struct tracking the asset at `assetSymbol` currently deposited by `wallet`
   */
  function loadBalanceBySymbol(address wallet, string calldata assetSymbol)
    external
    view
    override
    returns (Balance memory)
  {
    return
      _balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
        wallet,
        assetSymbol
      );
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
   * @notice Deposit quote token
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
        _quoteAssetAddress,
        _quoteAssetSymbol,
        _quoteAssetDecimals,
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
    Order calldata buy,
    Order calldata sell,
    OrderBookTrade calldata orderBookTrade,
    OraclePrice[] calldata buyOraclePrices,
    OraclePrice[] calldata sellOraclePrices
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
      // We wrap the arguments in a struct to avoid 'Stack too deep' errors
      ExecuteOrderBookTradeArguments(
        buy,
        sell,
        orderBookTrade,
        buyOraclePrices,
        sellOraclePrices,
        _quoteAssetDecimals,
        _quoteAssetSymbol,
        _delegateKeyExpirationPeriodInMs,
        _feeWallet,
        _oracleWallet
      ),
      _balanceTracking,
      _completedOrderHashes,
      _fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      _nonceInvalidationsByWallet,
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

  // Liquidation //

  /**
   * @notice Liquidates a single position below the market's configured `minimumPositionSizeInPips` to the Insurance
   * Fund at the current oracle price
   */
  function liquidatePositionBelowMinimum(
    string calldata baseAssetSymbol,
    address liquidatingWallet,
    int64 liquidationQuoteQuantityInPips,
    OraclePrice[] calldata insuranceFundOraclePrices,
    OraclePrice[] calldata liquidatingWalletOraclePrices
  ) external onlyDispatcher {
    Perpetual.liquidatePositionBelowMinimum(
      Liquidation.LiquidatePositionBelowMinimumArguments(
        baseAssetSymbol,
        liquidatingWallet,
        liquidationQuoteQuantityInPips,
        insuranceFundOraclePrices,
        liquidatingWalletOraclePrices,
        _positionBelowMinimumLiquidationPriceToleranceBasisPoints,
        _insuranceFundWallet,
        _oracleWallet,
        _quoteAssetDecimals,
        _quoteAssetSymbol
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      _fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Liquidates a single position in a deactivated market at the previously set oracle price
   */
  function liquidatePositionInDeactivatedMarket(
    string calldata baseAssetSymbol,
    address liquidatingWallet,
    int64 liquidationQuoteQuantityInPips,
    OraclePrice[] calldata liquidatingWalletOraclePrices
  ) external onlyDispatcher {
    Perpetual.liquidatePositionInDeactivatedMarket(
      Liquidation.LiquidatePositionInDeactivatedMarketArguments(
        baseAssetSymbol,
        liquidatingWallet,
        liquidationQuoteQuantityInPips,
        liquidatingWalletOraclePrices,
        _oracleWallet,
        _quoteAssetDecimals,
        _quoteAssetSymbol
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      _fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Liquidates all positions held by a wallet below maintenance requirements to the Insurance Fund at each
   * position's bankruptcy price
   */
  function liquidateWalletInMaintenance(
    address liquidatingWallet,
    int64[] calldata liquidationQuoteQuantitiesInPips,
    OraclePrice[] calldata insuranceFundOraclePrices,
    OraclePrice[] calldata liquidatingWalletOraclePrices
  ) external onlyDispatcher {
    Perpetual.liquidateWallet(
      Liquidation.LiquidateWalletArguments(
        LiquidationType.WalletInMaintenance,
        _insuranceFundWallet,
        insuranceFundOraclePrices,
        liquidatingWallet,
        liquidatingWalletOraclePrices,
        liquidationQuoteQuantitiesInPips,
        _oracleWallet,
        _quoteAssetDecimals,
        _quoteAssetSymbol
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      _fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Liquidates all positions held by a wallet below maintenance requirements to the Exit Fund at each
   * position's bankruptcy price
   */
  function liquidateWalletInMaintenanceDuringSystemRecovery(
    address liquidatingWallet,
    int64[] calldata liquidationQuoteQuantitiesInPips,
    OraclePrice[] calldata liquidatingWalletOraclePrices
  ) external onlyDispatcher {
    require(
      _baseAssetSymbolsWithOpenPositionsByWallet[_exitFundWallet].length > 0,
      'Exit Fund has no positions'
    );

    Perpetual.liquidateWallet(
      Liquidation.LiquidateWalletArguments(
        LiquidationType.WalletInMaintenanceDuringSystemRecovery,
        _exitFundWallet,
        new OraclePrice[](0),
        liquidatingWallet,
        liquidatingWalletOraclePrices,
        liquidationQuoteQuantitiesInPips,
        _oracleWallet,
        _quoteAssetDecimals,
        _quoteAssetSymbol
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      _fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Liquidates all positions of an exited wallet to the Insurance Fund at each position's exit price
   */
  function liquidateWalletExited(
    address liquidatingWallet,
    int64[] calldata liquidationQuoteQuantitiesInPips,
    OraclePrice[] calldata insuranceFundOraclePrices,
    OraclePrice[] calldata liquidatingWalletOraclePrices
  ) external onlyDispatcher {
    require(_walletExits[liquidatingWallet].exists, 'Wallet not exited');

    Perpetual.liquidateWallet(
      Liquidation.LiquidateWalletArguments(
        LiquidationType.WalletExited,
        _insuranceFundWallet,
        insuranceFundOraclePrices,
        liquidatingWallet,
        liquidatingWalletOraclePrices,
        liquidationQuoteQuantitiesInPips,
        _oracleWallet,
        _quoteAssetDecimals,
        _quoteAssetSymbol
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      _fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );
  }

  // Automatic Deleveraging (ADL) //

  /**
   * @notice Reduces a single position held by a wallet below maintenance requirements by deleveraging a counterparty
   * position at the bankruptcy price of the liquidating wallet
   */
  function deleverageInMaintenanceAcquisition(
    string calldata baseAssetSymbol,
    address deleveragingWallet,
    address liquidatingWallet,
    int64[] memory liquidationQuoteQuantitiesInPips,
    int64 liquidationBaseQuantityInPips,
    int64 liquidationQuoteQuantityInPips,
    OraclePrice[] calldata deleveragingWalletOraclePrices,
    OraclePrice[] calldata insuranceFundOraclePrices,
    OraclePrice[] calldata liquidatingWalletOraclePrices
  ) external onlyDispatcher {
    Perpetual.deleverageLiquidationAcquisition(
      Deleveraging.DeleverageLiquidationAcquisitionArguments(
        DeleverageType.InMaintenanceAcquisition,
        baseAssetSymbol,
        deleveragingWallet,
        liquidatingWallet,
        liquidationQuoteQuantitiesInPips,
        liquidationBaseQuantityInPips,
        liquidationQuoteQuantityInPips,
        deleveragingWalletOraclePrices,
        insuranceFundOraclePrices,
        liquidatingWalletOraclePrices,
        _quoteAssetDecimals,
        _quoteAssetSymbol,
        _insuranceFundWallet,
        _oracleWallet
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      _fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Reduces a single position held by the Insurance Fund by deleveraging a counterparty position at the entry
   * price of the Insurance Fund
   */
  function deleverageInsuranceFundClosure(
    string calldata baseAssetSymbol,
    address deleveragingWallet,
    int64 liquidationBaseQuantityInPips,
    int64 liquidationQuoteQuantityInPips,
    OraclePrice[] calldata deleveragingWalletOraclePrices,
    OraclePrice[] calldata insuranceFundOraclePrices
  ) external onlyDispatcher {
    Perpetual.deleverageLiquidationClosure(
      Deleveraging.DeleverageLiquidationClosureArguments(
        DeleverageType.InsuranceFundClosure,
        baseAssetSymbol,
        deleveragingWallet,
        _insuranceFundWallet,
        liquidationBaseQuantityInPips,
        liquidationQuoteQuantityInPips,
        insuranceFundOraclePrices,
        deleveragingWalletOraclePrices,
        _quoteAssetDecimals,
        _quoteAssetSymbol,
        _oracleWallet
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      _fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Reduces a single position held by an exited wallet by deleveraging a counterparty position at the exit
   * price of the liquidating wallet
   */
  function deleverageExitAcquisition(
    string calldata baseAssetSymbol,
    address deleveragingWallet,
    address liquidatingWallet,
    int64[] memory liquidationQuoteQuantitiesInPips,
    int64 liquidationBaseQuantityInPips,
    int64 liquidationQuoteQuantityInPips,
    OraclePrice[] calldata deleveragingWalletOraclePrices,
    OraclePrice[] calldata insuranceFundOraclePrices,
    OraclePrice[] calldata liquidatingWalletOraclePrices
  ) external onlyDispatcher {
    require(_walletExits[liquidatingWallet].exists, 'Wallet not exited');

    Perpetual.deleverageLiquidationAcquisition(
      Deleveraging.DeleverageLiquidationAcquisitionArguments(
        DeleverageType.ExitAcquisition,
        baseAssetSymbol,
        deleveragingWallet,
        liquidatingWallet,
        liquidationQuoteQuantitiesInPips,
        liquidationBaseQuantityInPips,
        liquidationQuoteQuantityInPips,
        deleveragingWalletOraclePrices,
        insuranceFundOraclePrices,
        liquidatingWalletOraclePrices,
        _quoteAssetDecimals,
        _quoteAssetSymbol,
        _insuranceFundWallet,
        _oracleWallet
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      _fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Reduces a single position held by the Exit Fund by deleveraging a counterparty position at the oracle
   * price or the Exit Fund's bankruptcy price if the Exit Fund account value is positive or negative, respectively
   */
  function deleverageExitFundClosure(
    string calldata baseAssetSymbol,
    address deleveragingWallet,
    int64 liquidationBaseQuantityInPips,
    int64 liquidationQuoteQuantityInPips,
    OraclePrice[] calldata deleveragingWalletOraclePrices,
    OraclePrice[] calldata exitFundOraclePrices
  ) external onlyDispatcher {
    Perpetual.deleverageLiquidationClosure(
      Deleveraging.DeleverageLiquidationClosureArguments(
        DeleverageType.ExitFundClosure,
        baseAssetSymbol,
        deleveragingWallet,
        _exitFundWallet,
        liquidationBaseQuantityInPips,
        liquidationQuoteQuantityInPips,
        exitFundOraclePrices,
        deleveragingWalletOraclePrices,
        _quoteAssetDecimals,
        _quoteAssetSymbol,
        _oracleWallet
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      _fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );
  }

  // Withdrawing //

  /**
   * @notice Settles a user withdrawal submitted off-chain. Calls restricted to currently
   * whitelisted Dispatcher wallet
   *
   * @param withdrawal A `Withdrawal` struct encoding the parameters of the withdrawal
   */
  function withdraw(
    Withdrawal memory withdrawal,
    OraclePrice[] calldata oraclePrices
  ) public onlyDispatcher {
    require(!isWalletExitFinalized(withdrawal.walletAddress), 'Wallet exited');

    int64 newExchangeBalanceInPips = Withdrawing.withdraw(
      Withdrawing.WithdrawArguments(
        withdrawal,
        oraclePrices,
        _quoteAssetAddress,
        _quoteAssetDecimals,
        _quoteAssetSymbol,
        _custodian,
        _feeWallet,
        _oracleWallet
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      _completedWithdrawalHashes,
      _fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );

    emit Withdrawn(
      withdrawal.walletAddress,
      withdrawal.grossQuantityInPips,
      newExchangeBalanceInPips
    );
  }

  // Market management //

  function addMarket(Market calldata newMarket) external onlyAdmin {
    MarketAdmin.addMarket(newMarket, _marketsByBaseAssetSymbol);
  }

  // TODO Update market

  function activateMarket(string calldata baseAssetSymbol)
    external
    onlyDispatcher
  {
    MarketAdmin.activateMarket(baseAssetSymbol, _marketsByBaseAssetSymbol);
  }

  function deactivateMarket(
    string calldata baseAssetSymbol,
    OraclePrice memory oraclePrice
  ) external onlyDispatcher {
    MarketAdmin.deactivateMarket(
      baseAssetSymbol,
      oraclePrice,
      _oracleWallet,
      _quoteAssetDecimals,
      _marketsByBaseAssetSymbol
    );
  }

  // TODO Validations
  function setMarketOverrides(address wallet, Market calldata marketOverrides)
    external
    onlyAdmin
  {
    MarketAdmin.setMarketOverrides(
      wallet,
      marketOverrides,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );
  }

  // Perps //

  /**
   * @notice Validates oracle signature. Validates oracleTimestampInMs is exactly one hour after
   * _lastFundingRatePublishTimestampInMs. Pushes fundingRate × oraclePrice to
   * _fundingMultipliersByBaseAssetAddress
   * TODO Validate funding rates
   */
  function publishFundingMutipliers(
    OraclePrice[] calldata oraclePrices,
    int64[] calldata fundingRatesInPips
  ) external onlyDispatcher {
    Perpetual.publishFundingMutipliers(
      oraclePrices,
      fundingRatesInPips,
      _quoteAssetDecimals,
      _oracleWallet,
      _fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol
    );
  }

  /**
   * @notice True-ups base position funding debits/credits by walking all funding multipliers
   * published since last position update
   * TODO Readonly version
   */
  function updateWalletFunding(address wallet) public onlyDispatcher {
    Perpetual.updateWalletFunding(
      wallet,
      _quoteAssetSymbol,
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      _fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Calculate total outstanding funding payments
   */
  function loadOutstandingWalletFunding(address wallet)
    external
    view
    returns (int64)
  {
    return
      Perpetual.loadOutstandingWalletFunding(
        wallet,
        _balanceTracking,
        _baseAssetSymbolsWithOpenPositionsByWallet,
        _fundingMultipliersByBaseAssetSymbol,
        _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        _marketsByBaseAssetSymbol
      );
  }

  /**
   * @notice Calculate total account value by formula Q + Σ (Si × Pi). Note Q and S can be negative
   */
  function loadTotalAccountValue(
    address wallet,
    OraclePrice[] calldata oraclePrices
  ) external view returns (int64) {
    return
      Perpetual.loadTotalAccountValueIncludingOutstandingWalletFunding(
        Margin.LoadArguments(
          wallet,
          oraclePrices,
          _oracleWallet,
          _quoteAssetDecimals,
          _quoteAssetSymbol
        ),
        _balanceTracking,
        _baseAssetSymbolsWithOpenPositionsByWallet,
        _fundingMultipliersByBaseAssetSymbol,
        _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        _marketsByBaseAssetSymbol
      );
  }

  /**
   * @notice Calculate total initial margin requirement with formula Σ abs(Si × Pi × Ii). Note S can be negative
   */
  function loadTotalInitialMarginRequirement(
    address wallet,
    OraclePrice[] calldata oraclePrices
  ) external view returns (uint64) {
    return
      Perpetual.loadTotalInitialMarginRequirement(
        wallet,
        oraclePrices,
        _quoteAssetDecimals,
        _oracleWallet,
        _balanceTracking,
        _baseAssetSymbolsWithOpenPositionsByWallet,
        _marketOverridesByBaseAssetSymbolAndWallet,
        _marketsByBaseAssetSymbol
      );
  }

  /**
   * @notice Calculate total maintenance margin requirement by formula Σ abs(Si × Pi × Mi). Note S can be negative
   */
  function loadTotalMaintenanceMarginRequirement(
    address wallet,
    OraclePrice[] calldata oraclePrices
  ) external view returns (uint64) {
    return
      Perpetual.loadTotalMaintenanceMarginRequirement(
        wallet,
        oraclePrices,
        _quoteAssetDecimals,
        _oracleWallet,
        _balanceTracking,
        _baseAssetSymbolsWithOpenPositionsByWallet,
        _marketOverridesByBaseAssetSymbolAndWallet,
        _marketsByBaseAssetSymbol
      );
  }

  // Wallet exits //

  /**
   * @notice Flags the sending wallet as exited, immediately disabling deposits and on-chain
   * intitiation of liquidity changes upon mining. After the Chain Propagation Period passes
   * trades, withdrawals, and liquidity change executions are also disabled for the wallet,
   * and assets may then be withdrawn one at a time via `withdrawExit`
   */
  function exitWallet() external {
    require(!_walletExits[msg.sender].exists, 'Wallet already exited');

    _walletExits[msg.sender] = WalletExit(
      true,
      block.number + _chainPropagationPeriodInBlocks
    );

    emit WalletExited(
      msg.sender,
      block.number + _chainPropagationPeriodInBlocks
    );
  }

  /**
   * @notice Withdraw the entire balance of an asset for an exited wallet. The Chain Propagation
   * Period must have already passed since calling `exitWallet`
   *
   */
  function withdrawExit(address wallet, OraclePrice[] calldata oraclePrices)
    external
  {
    require(isWalletExitFinalized(wallet), 'Wallet exit not finalized');

    uint64 quantityInPips = Withdrawing.withdrawExit(
      Withdrawing.WithdrawExitArguments(
        wallet,
        oraclePrices,
        _custodian,
        _exitFundWallet,
        _oracleWallet,
        _quoteAssetAddress,
        _quoteAssetDecimals,
        _quoteAssetSymbol
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      _fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );

    emit WalletExitWithdrawn(wallet, quantityInPips);
  }

  /**
   * @notice Clears exited status of sending wallet. Upon mining immediately enables
   * deposits, trades, and withdrawals by sending wallet
   */
  function clearWalletExit() external {
    require(isWalletExitFinalized(msg.sender), 'Wallet exit not finalized');

    delete _walletExits[msg.sender];

    emit WalletExitCleared(msg.sender);
  }

  function isWalletExitFinalized(address wallet) internal view returns (bool) {
    WalletExit storage exit = _walletExits[wallet];
    return exit.exists && exit.effectiveBlockNumber <= block.number;
  }

  // Invalidation //

  /**
   * @notice Invalidate all order nonces with a timestampInMs lower than the one provided
   *
   * @param nonce A Version 1 UUID. After calling and once the Chain Propagation Period has
   * elapsed, `executeOrderBookTrade` will reject order nonces from this wallet with a
   * timestampInMs component lower than the one provided
   */
  function invalidateOrderNonce(uint128 nonce) external {
    (
      uint64 timestampInMs,
      uint256 effectiveBlockNumber
    ) = _nonceInvalidationsByWallet.invalidateOrderNonce(
        nonce,
        _chainPropagationPeriodInBlocks
      );

    emit OrderNonceInvalidated(
      msg.sender,
      nonce,
      timestampInMs,
      effectiveBlockNumber
    );
  }
}
