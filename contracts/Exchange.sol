// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { AcquisitionDeleveraging } from "./libraries/AcquisitionDeleveraging.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { AssetUnitConversions } from "./libraries/AssetUnitConversions.sol";
import { BalanceTracking } from "./libraries/BalanceTracking.sol";
import { ClosureDeleveraging } from "./libraries/ClosureDeleveraging.sol";
import { Constants } from "./libraries/Constants.sol";
import { Depositing } from "./libraries/Depositing.sol";
import { ExitFund } from "./libraries/ExitFund.sol";
import { Funding } from "./libraries/Funding.sol";
import { Hashing } from "./libraries/Hashing.sol";
import { Liquidation } from "./libraries/Liquidation.sol";
import { Margin } from "./libraries/Margin.sol";
import { MarketAdmin } from "./libraries/MarketAdmin.sol";
import { NonceInvalidations } from "./libraries/NonceInvalidations.sol";
import { Owned } from "./Owned.sol";
import { String } from "./libraries/String.sol";
import { Trading } from "./libraries/Trading.sol";
import { Withdrawing } from "./libraries/Withdrawing.sol";
import { Balance, ExecuteOrderBookTradeArguments, FundingMultiplierQuartet, Market, IndexPrice, Order, OrderBookTrade, NonceInvalidation, Withdrawal } from "./libraries/Structs.sol";
import { DeleverageType, LiquidationType, OrderSide } from "./libraries/Enums.sol";
import { ICustodian, IExchange } from "./libraries/Interfaces.sol";

// solhint-disable-next-line contract-name-camelcase
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
  event DelegateKeyExpirationPeriodChanged(uint256 previousValue, uint256 newValue);
  /**
   * @notice Emitted when an admin changes the Exit Fund Wallet tunable parameter with `setExitFundWallet`
   */
  event ExitFundWalletChanged(address previousValue, address newValue);
  /**
   * @notice Emitted when an admin changes the Fee Wallet tunable parameter with `setFeeWallet`
   */
  event FeeWalletChanged(address previousValue, address newValue);
  /**
   * @notice Emitted when an admin changes the Insurance Fund Wallet tunable parameter with `setInsuranceFundWallet`
   */
  event InsuranceFundWalletChanged(address previousValue, address newValue);
  /**
   * @notice Emitted when an admin changes the position below minimum liquidation price tolerance tunable parameter
   * with `setPositionBelowMinimumLiquidationPriceToleranceMultiplier`
   */
  event PositionBelowMinimumLiquidationPriceToleranceMultiplierChanged(uint256 previousValue, uint256 newValue);
  /**
   * @notice Emitted when a user deposits quote tokens with `deposit`
   */
  event Deposited(uint64 index, address wallet, uint64 quantityInPips, int64 newExchangeBalanceInPips);
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
  event OrderNonceInvalidated(address wallet, uint128 nonce, uint128 timestampInMs, uint256 effectiveBlockNumber);
  /**
   * @notice Emitted when the Dispatcher Wallet submits a withdrawal with `withdraw`
   */
  event Withdrawn(address wallet, uint64 quantityInPips, int64 newExchangeBalanceInPips);

  // Internally used structs //

  struct WalletExit {
    bool exists;
    uint256 effectiveBlockNumber;
  }

  // Storage - state //

  // Balance tracking
  BalanceTracking.Storage public balanceTracking;
  // Mapping of wallet => list of base asset symbols with open positions
  mapping(address => string[]) public baseAssetSymbolsWithOpenPositionsByWallet;
  // CLOB - mapping of order wallet hash => isComplete
  mapping(bytes32 => bool) public completedOrderHashes;
  // Withdrawals - mapping of withdrawal wallet hash => isComplete
  mapping(bytes32 => bool) public completedWithdrawalHashes;
  // Fund custody contract
  ICustodian public custodian;
  // Deposit index
  uint64 public depositIndex;
  // Zero only if Exit Fund has no open positions or quote balance
  uint256 public exitFundPositionOpenedAtBlockNumber;
  // If positive (index increases) longs pay shorts; if negative (index decreases) shorts pay longs
  mapping(string => FundingMultiplierQuartet[]) public fundingMultipliersByBaseAssetSymbol;
  // Milliseconds since epoch, always aligned to hour
  mapping(string => uint64) public lastFundingRatePublishTimestampInMsByBaseAssetSymbol;
  // Wallet-specific market parameter overrides
  mapping(string => mapping(address => Market)) public marketOverridesByBaseAssetSymbolAndWallet;
  // Markets
  mapping(string => Market) public marketsByBaseAssetSymbol;
  // CLOB - mapping of wallet => last invalidated timestampInMs
  mapping(address => NonceInvalidation) public nonceInvalidationsByWallet;
  // CLOB - mapping of order hash => filled quantity in pips
  mapping(bytes32 => uint64) public partiallyFilledOrderQuantitiesInPips;
  // Address of ERC20 contract used as collateral and quote for all markets
  address public immutable quoteAssetAddress;
  // Exits
  mapping(address => WalletExit) public walletExits;

  // Storage - tunable parameters //

  uint256 public chainPropagationPeriodInBlocks;
  uint64 public delegateKeyExpirationPeriodInMs;
  uint64 public positionBelowMinimumLiquidationPriceToleranceMultiplier;
  address public dispatcherWallet;
  address public exitFundWallet;
  // TODO Upgrade through Governance
  address[] public indexPriceCollectionServiceWallets;
  // TODO Upgrade through Governance
  address public insuranceFundWallet;
  address public feeWallet;

  // Storage - private //

  /**
   * @notice Instantiate a new `Exchange` contract
   *
   * @dev Sets `balanceTracking.migrationSource` to first argument, and `_owner` and `_admin` to
   * `msg.sender`
   */
  constructor(
    IExchange balanceMigrationSource,
    address _quoteAssetAddress,
    address _exitFundWallet,
    address _feeWallet,
    address _insuranceFundWallet,
    address[] memory _indexPriceCollectionServiceWallets
  ) Owned() {
    require(
      address(balanceMigrationSource) == address(0x0) || Address.isContract(address(balanceMigrationSource)),
      "Invalid migration source"
    );
    balanceTracking.migrationSource = balanceMigrationSource;

    require(Address.isContract(address(_quoteAssetAddress)), "Invalid quote asset address");
    quoteAssetAddress = _quoteAssetAddress;

    setExitFundWallet(_exitFundWallet);

    setFeeWallet(_feeWallet);

    setInsuranceFundWallet(_insuranceFundWallet);

    for (uint8 i = 0; i < _indexPriceCollectionServiceWallets.length; i++) {
      require(address(_indexPriceCollectionServiceWallets[i]) != address(0x0), "Invalid IPCS wallet");
    }
    indexPriceCollectionServiceWallets = _indexPriceCollectionServiceWallets;

    // Deposits must be manually enabled via `setDepositIndex`
    depositIndex = Constants.DEPOSIT_INDEX_NOT_SET;
  }

  // Tunable parameters //

  /**
   * @notice Sets a new Chain Propagation Period - the block delay after which order nonce invalidations
   * are respected by `executeOrderBookTrade` and wallet exits are respected by `executeOrderBookTrade` and `withdraw`
   *
   * @param newChainPropagationPeriodInBlocks The new Chain Propagation Period expressed as a number of blocks. Must
   * be less than `Constants.MAX_CHAIN_PROPAGATION_PERIOD_IN_BLOCKS`
   */
  function setChainPropagationPeriod(uint256 newChainPropagationPeriodInBlocks) external onlyAdmin {
    require(
      newChainPropagationPeriodInBlocks < Constants.MAX_CHAIN_PROPAGATION_PERIOD_IN_BLOCKS,
      "Must be less than 1 week"
    );

    uint256 oldChainPropagationPeriodInBlocks = chainPropagationPeriodInBlocks;
    chainPropagationPeriodInBlocks = newChainPropagationPeriodInBlocks;

    emit ChainPropagationPeriodChanged(oldChainPropagationPeriodInBlocks, newChainPropagationPeriodInBlocks);
  }

  /**
   * @notice Sets a new Delegate Key Expiration Period - the delay following a delegated key's nonce timestamp after
   * which it cannot be used to sign orders
   *
   * @param newDelegateKeyExpirationPeriodInMs The new Delegate Key Expiration Period expressed as milliseconds. Must
   * be less than `Constants.MAX_DELEGATE_KEY_EXPIRATION_PERIOD_IN_MS`
   */
  function setDelegateKeyExpirationPeriod(uint64 newDelegateKeyExpirationPeriodInMs) external onlyAdmin {
    require(
      newDelegateKeyExpirationPeriodInMs < Constants.MAX_DELEGATE_KEY_EXPIRATION_PERIOD_IN_MS,
      "Must be less than 1 year"
    );

    uint64 oldDelegateKeyExpirationPeriodInMs = delegateKeyExpirationPeriodInMs;
    delegateKeyExpirationPeriodInMs = newDelegateKeyExpirationPeriodInMs;

    emit DelegateKeyExpirationPeriodChanged(oldDelegateKeyExpirationPeriodInMs, newDelegateKeyExpirationPeriodInMs);
  }

  /**
   * @notice Sets a new position below minimum liquidation price tolerance multiplier
   *
   * @param newPositionBelowMinimumLiquidationPriceToleranceMultiplier The new position below minimum liquidation price
   * tolerance multiplier expressed in decimal pips * 10^8. Must be less than `Constants.MAX_FEE_MULTIPLIER`
   */
  function setPositionBelowMinimumLiquidationPriceToleranceMultiplier(
    uint64 newPositionBelowMinimumLiquidationPriceToleranceMultiplier
  ) external onlyAdmin {
    // TODO Do we want a separate constant cap for this?
    require(
      newPositionBelowMinimumLiquidationPriceToleranceMultiplier < Constants.MAX_FEE_MULTIPLIER,
      "Must be less than 20 percent"
    );

    uint64 oldPositionBelowMinimumLiquidationPriceToleranceMultiplier = positionBelowMinimumLiquidationPriceToleranceMultiplier;
    positionBelowMinimumLiquidationPriceToleranceMultiplier = newPositionBelowMinimumLiquidationPriceToleranceMultiplier;

    emit PositionBelowMinimumLiquidationPriceToleranceMultiplierChanged(
      oldPositionBelowMinimumLiquidationPriceToleranceMultiplier,
      newPositionBelowMinimumLiquidationPriceToleranceMultiplier
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
    require(custodian == ICustodian(payable(address(0x0))), "Custodian can only be set once");
    require(Address.isContract(address(newCustodian)), "Invalid address");

    custodian = newCustodian;
  }

  /**
   * @notice Enable depositing assets into the Exchange by setting the current deposit index from
   * the old Exchange contract's value. This function can only be called once
   *
   */
  function setDepositIndex() external onlyAdmin {
    require(depositIndex == Constants.DEPOSIT_INDEX_NOT_SET, "Can only be set once");

    depositIndex = address(balanceTracking.migrationSource) == address(0x0)
      ? 0
      : balanceTracking.migrationSource.depositIndex();
  }

  /**
   * @notice Sets the address of the Exit Fund wallet
   *
   * @dev The current Exit Fund wallet cannot have any open balances
   * @dev Visibility public instead of external to allow invocation from `constructor`
   *
   * @param newExitFundWallet The new Exit Fund wallet. Must be different from the current one
   */
  function setExitFundWallet(address newExitFundWallet) public onlyAdmin {
    require(newExitFundWallet != address(0x0), "Invalid EF wallet address");
    require(newExitFundWallet != exitFundWallet, "Must be different from current");

    (, bool isExitFundBalanceOpen) = ExitFund.isExitFundPositionOrBalanceOpen(
      exitFundWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet
    );
    require(!isExitFundBalanceOpen, "EF cannot have open balance");

    address oldExitFundWallet = exitFundWallet;
    exitFundWallet = newExitFundWallet;

    emit ExitFundWalletChanged(oldExitFundWallet, newExitFundWallet);
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
    require(newFeeWallet != address(0x0), "Invalid fee wallet address");
    require(newFeeWallet != feeWallet, "Must be different from current");

    address oldFeeWallet = feeWallet;
    feeWallet = newFeeWallet;

    emit FeeWalletChanged(oldFeeWallet, newFeeWallet);
  }

  /**
   * @notice Sets the address of the Insurance Fund wallet
   *
   * @dev Visibility public instead of external to allow invocation from `constructor`
   *
   * @param newInsuranceFundWallet The new Insurance Fund wallet. Must be different from the current one
   */
  function setInsuranceFundWallet(address newInsuranceFundWallet) public onlyAdmin {
    require(newInsuranceFundWallet != address(0x0), "Invalid IF wallet address");
    require(newInsuranceFundWallet != insuranceFundWallet, "Must be different from current");

    address oldInsuranceFundWallet = insuranceFundWallet;
    insuranceFundWallet = newInsuranceFundWallet;

    emit InsuranceFundWalletChanged(oldInsuranceFundWallet, newInsuranceFundWallet);
  }

  /**
   * @notice Load a wallet's balance-tracking struct by asset symbol
   *
   * @param wallet The wallet address to load the balance for. Can be different from `msg.sender`
   * @param assetSymbol The asset symbol to load the wallet's balance for
   *
   * @return The internal `Balance` struct tracking the asset at `assetSymbol` currently deposited by `wallet`
   */
  function loadBalanceStructBySymbol(
    address wallet,
    string calldata assetSymbol
  ) external view override returns (Balance memory) {
    return balanceTracking.loadBalanceStructFromMigrationSourceIfNeeded(wallet, assetSymbol);
  }

  /**
   * @notice Load a wallet's balance by asset symbol, in pips
   *
   * @param wallet The wallet address to load the balance for. Can be different from `msg.sender`
   * @param assetSymbol The asset symbol to load the wallet's balance for
   *
   * @return balance The quantity denominated in pips of asset at `assetSymbol` currently deposited by `wallet`
   */
  function loadBalanceBySymbol(
    address wallet,
    string calldata assetSymbol
  ) external view override returns (int64 balance) {
    balance = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, assetSymbol);

    if (String.isEqual(assetSymbol, Constants.QUOTE_ASSET_SYMBOL)) {
      balance += Funding.loadOutstandingWalletFunding(
        wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsByBaseAssetSymbol
      );
    }
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
  function loadPartiallyFilledOrderQuantityInPips(bytes32 orderHash) external view returns (uint64) {
    return partiallyFilledOrderQuantitiesInPips[orderHash];
  }

  // Dispatcher whitelisting //

  /**
   * @notice Sets the wallet whitelisted to dispatch transactions calling the
   * `executeOrderBookTrade` and `withdraw` functions
   *
   * @param newDispatcherWallet The new whitelisted dispatcher wallet. Must be different from the
   * current one
   */
  function setDispatcher(address newDispatcherWallet) external onlyAdmin {
    require(newDispatcherWallet != address(0x0), "Invalid wallet address");
    require(newDispatcherWallet != dispatcherWallet, "Must be different from current");
    dispatcherWallet = newDispatcherWallet;
  }

  /**
   * @notice Clears the currently set whitelisted dispatcher wallet, effectively disabling calling
   * the `executeOrderBookTrade`, `withdraw` functions until a new wallet is set with
   * `setDispatcher`
   */
  function removeDispatcher() external onlyAdmin {
    dispatcherWallet = address(0x0);
  }

  modifier onlyDispatcher() {
    require(msg.sender == dispatcherWallet, "Caller is not dispatcher");
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
    require(depositIndex != Constants.DEPOSIT_INDEX_NOT_SET, "Deposits disabled");

    // Calling exitWallet disables deposits immediately on mining, in contrast to withdrawals and
    // trades which respect the Chain Propagation Period given by `effectiveBlockNumber` via
    // `_isWalletExitFinalized`
    require(!walletExits[msg.sender].exists, "Wallet exited");

    (uint64 quantityInPips, int64 newExchangeBalanceInPips) = Depositing.deposit(
      msg.sender,
      quantityInAssetUnits,
      quoteAssetAddress,
      custodian,
      balanceTracking
    );

    depositIndex++;

    emit Deposited(depositIndex, msg.sender, quantityInPips, newExchangeBalanceInPips);
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
    IndexPrice[] calldata buyIndexPrices,
    IndexPrice[] calldata sellIndexPrices
  ) external onlyDispatcher {
    require(!_isWalletExitFinalized(buy.wallet), "Buy wallet exit finalized");
    require(!_isWalletExitFinalized(sell.wallet), "Sell wallet exit finalized");

    Trading.executeOrderBookTrade(
      // We wrap the arguments in a struct to avoid 'Stack too deep' errors
      ExecuteOrderBookTradeArguments(
        buy,
        sell,
        orderBookTrade,
        buyIndexPrices,
        sellIndexPrices,
        delegateKeyExpirationPeriodInMs,
        exitFundWallet,
        feeWallet,
        insuranceFundWallet,
        indexPriceCollectionServiceWallets
      ),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      completedOrderHashes,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol,
      nonceInvalidationsByWallet,
      partiallyFilledOrderQuantitiesInPips
    );

    emit OrderBookTradeExecuted(
      buy.wallet,
      sell.wallet,
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
   * Fund at the current index price
   */
  function liquidatePositionBelowMinimum(
    string calldata baseAssetSymbol,
    address liquidatingWallet,
    int64 liquidationQuoteQuantityInPips,
    IndexPrice[] calldata insuranceFundIndexPrices,
    IndexPrice[] calldata liquidatingWalletIndexPrices
  ) external onlyDispatcher {
    Liquidation.liquidatePositionBelowMinimum(
      Liquidation.LiquidatePositionBelowMinimumArguments(
        baseAssetSymbol,
        liquidatingWallet,
        liquidationQuoteQuantityInPips,
        insuranceFundIndexPrices,
        liquidatingWalletIndexPrices,
        positionBelowMinimumLiquidationPriceToleranceMultiplier,
        insuranceFundWallet,
        indexPriceCollectionServiceWallets
      ),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Liquidates a single position in a deactivated market at the previously set index price
   */
  function liquidatePositionInDeactivatedMarket(
    string calldata baseAssetSymbol,
    address liquidatingWallet,
    int64 liquidationQuoteQuantityInPips,
    IndexPrice[] calldata liquidatingWalletIndexPrices
  ) external onlyDispatcher {
    Liquidation.liquidatePositionInDeactivatedMarket(
      Liquidation.LiquidatePositionInDeactivatedMarketArguments(
        baseAssetSymbol,
        liquidatingWallet,
        liquidationQuoteQuantityInPips,
        liquidatingWalletIndexPrices,
        indexPriceCollectionServiceWallets
      ),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Liquidates all positions held by a wallet below maintenance requirements to the Insurance Fund at each
   * position's bankruptcy price
   */
  function liquidateWalletInMaintenance(
    address liquidatingWallet,
    int64[] calldata liquidationQuoteQuantitiesInPips,
    IndexPrice[] calldata insuranceFundIndexPrices,
    IndexPrice[] calldata liquidatingWalletIndexPrices
  ) external onlyDispatcher {
    Liquidation.liquidateWallet(
      Liquidation.LiquidateWalletArguments(
        LiquidationType.WalletInMaintenance,
        insuranceFundWallet,
        insuranceFundIndexPrices,
        liquidatingWallet,
        liquidatingWalletIndexPrices,
        liquidationQuoteQuantitiesInPips,
        indexPriceCollectionServiceWallets
      ),
      0,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Liquidates all positions held by a wallet below maintenance requirements to the Exit Fund at each
   * position's bankruptcy price
   */
  function liquidateWalletInMaintenanceDuringSystemRecovery(
    address liquidatingWallet,
    int64[] calldata liquidationQuoteQuantitiesInPips,
    IndexPrice[] calldata liquidatingWalletIndexPrices
  ) external onlyDispatcher {
    require(exitFundPositionOpenedAtBlockNumber > 0, "Exit Fund has no positions");

    exitFundPositionOpenedAtBlockNumber = Liquidation.liquidateWallet(
      Liquidation.LiquidateWalletArguments(
        LiquidationType.WalletInMaintenanceDuringSystemRecovery,
        exitFundWallet,
        new IndexPrice[](0),
        liquidatingWallet,
        liquidatingWalletIndexPrices,
        liquidationQuoteQuantitiesInPips,
        indexPriceCollectionServiceWallets
      ),
      exitFundPositionOpenedAtBlockNumber,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Liquidates all positions of an exited wallet to the Insurance Fund at each position's exit price
   */
  function liquidateWalletExited(
    address liquidatingWallet,
    int64[] calldata liquidationQuoteQuantitiesInPips,
    IndexPrice[] calldata insuranceFundIndexPrices,
    IndexPrice[] calldata liquidatingWalletIndexPrices
  ) external onlyDispatcher {
    require(walletExits[liquidatingWallet].exists, "Wallet not exited");

    Liquidation.liquidateWallet(
      Liquidation.LiquidateWalletArguments(
        LiquidationType.WalletExited,
        insuranceFundWallet,
        insuranceFundIndexPrices,
        liquidatingWallet,
        liquidatingWalletIndexPrices,
        liquidationQuoteQuantitiesInPips,
        indexPriceCollectionServiceWallets
      ),
      0,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
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
    IndexPrice[] calldata deleveragingWalletIndexPrices,
    IndexPrice[] calldata insuranceFundIndexPrices,
    IndexPrice[] calldata liquidatingWalletIndexPrices
  ) external onlyDispatcher {
    AcquisitionDeleveraging.deleverage(
      AcquisitionDeleveraging.Arguments(
        DeleverageType.WalletInMaintenance,
        baseAssetSymbol,
        deleveragingWallet,
        liquidatingWallet,
        liquidationQuoteQuantitiesInPips,
        liquidationBaseQuantityInPips,
        liquidationQuoteQuantityInPips,
        deleveragingWalletIndexPrices,
        insuranceFundIndexPrices,
        liquidatingWalletIndexPrices,
        insuranceFundWallet,
        indexPriceCollectionServiceWallets
      ),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
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
    IndexPrice[] calldata deleveragingWalletIndexPrices,
    IndexPrice[] calldata insuranceFundIndexPrices
  ) external onlyDispatcher {
    ClosureDeleveraging.deleverage(
      ClosureDeleveraging.Arguments(
        DeleverageType.InsuranceFundClosure,
        baseAssetSymbol,
        deleveragingWallet,
        insuranceFundWallet,
        liquidationBaseQuantityInPips,
        liquidationQuoteQuantityInPips,
        insuranceFundIndexPrices,
        deleveragingWalletIndexPrices,
        indexPriceCollectionServiceWallets
      ),
      0,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
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
    IndexPrice[] calldata deleveragingWalletIndexPrices,
    IndexPrice[] calldata insuranceFundIndexPrices,
    IndexPrice[] calldata liquidatingWalletIndexPrices
  ) external onlyDispatcher {
    require(walletExits[liquidatingWallet].exists, "Wallet not exited");

    AcquisitionDeleveraging.deleverage(
      AcquisitionDeleveraging.Arguments(
        DeleverageType.WalletExited,
        baseAssetSymbol,
        deleveragingWallet,
        liquidatingWallet,
        liquidationQuoteQuantitiesInPips,
        liquidationBaseQuantityInPips,
        liquidationQuoteQuantityInPips,
        deleveragingWalletIndexPrices,
        insuranceFundIndexPrices,
        liquidatingWalletIndexPrices,
        insuranceFundWallet,
        indexPriceCollectionServiceWallets
      ),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Reduces a single position held by the Exit Fund by deleveraging a counterparty position at the index
   * price or the Exit Fund's bankruptcy price if the Exit Fund account value is positive or negative, respectively
   */
  function deleverageExitFundClosure(
    string calldata baseAssetSymbol,
    address deleveragingWallet,
    int64 liquidationBaseQuantityInPips,
    int64 liquidationQuoteQuantityInPips,
    IndexPrice[] calldata deleveragingWalletIndexPrices,
    IndexPrice[] calldata exitFundIndexPrices
  ) external onlyDispatcher {
    exitFundPositionOpenedAtBlockNumber = ClosureDeleveraging.deleverage(
      ClosureDeleveraging.Arguments(
        DeleverageType.ExitFundClosure,
        baseAssetSymbol,
        deleveragingWallet,
        exitFundWallet,
        liquidationBaseQuantityInPips,
        liquidationQuoteQuantityInPips,
        exitFundIndexPrices,
        deleveragingWalletIndexPrices,
        indexPriceCollectionServiceWallets
      ),
      exitFundPositionOpenedAtBlockNumber,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  // Withdrawing //

  /**
   * @notice Settles a user withdrawal submitted off-chain. Calls restricted to currently
   * whitelisted Dispatcher wallet
   *
   * @param withdrawal A `Withdrawal` struct encoding the parameters of the withdrawal
   */
  function withdraw(Withdrawal memory withdrawal, IndexPrice[] calldata indexPrices) public onlyDispatcher {
    require(!_isWalletExitFinalized(withdrawal.wallet), "Wallet exited");

    int64 newExchangeBalanceInPips = Withdrawing.withdraw(
      Withdrawing.WithdrawArguments(
        withdrawal,
        indexPrices,
        quoteAssetAddress,
        custodian,
        exitFundPositionOpenedAtBlockNumber,
        exitFundWallet,
        feeWallet,
        indexPriceCollectionServiceWallets
      ),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      completedWithdrawalHashes,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    emit Withdrawn(withdrawal.wallet, withdrawal.grossQuantityInPips, newExchangeBalanceInPips);
  }

  // Market management //

  function addMarket(Market calldata newMarket) external onlyAdmin {
    MarketAdmin.addMarket(newMarket, marketsByBaseAssetSymbol);
  }

  // TODO Update market

  function activateMarket(string calldata baseAssetSymbol) external onlyDispatcher {
    MarketAdmin.activateMarket(baseAssetSymbol, marketsByBaseAssetSymbol);
  }

  function deactivateMarket(string calldata baseAssetSymbol, IndexPrice memory indexPrice) external onlyDispatcher {
    MarketAdmin.deactivateMarket(
      baseAssetSymbol,
      indexPrice,
      indexPriceCollectionServiceWallets,
      marketsByBaseAssetSymbol
    );
  }

  // TODO Validations
  function setMarketOverrides(address wallet, Market calldata marketOverrides) external onlyAdmin {
    MarketAdmin.setMarketOverrides(
      wallet,
      marketOverrides,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  // Perps //

  /**
   * @notice Validates index signatures. Validates indexTimestampInMs is exactly one hour after
   * _lastFundingRatePublishTimestampInMs. Pushes fundingRate × indexPrice to _fundingMultipliersByBaseAssetAddress
   * TODO Validate funding rates
   */
  function publishFundingMutipliers(
    int64[] calldata fundingRatesInPips,
    IndexPrice[] calldata indexPrices
  ) external onlyDispatcher {
    Funding.publishFundingMutipliers(
      fundingRatesInPips,
      indexPrices,
      indexPriceCollectionServiceWallets,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol
    );
  }

  /**
   * @notice True-ups base position funding debits/credits by walking all funding multipliers
   * published since last position update
   */
  function updateWalletFunding(address wallet) public onlyDispatcher {
    Funding.updateWalletFunding(
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Calculate total outstanding funding payments
   */
  function loadOutstandingWalletFunding(address wallet) external view returns (int64) {
    return
      Funding.loadOutstandingWalletFunding(
        wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsByBaseAssetSymbol
      );
  }

  /**
   * @notice Calculate total account value by formula Q + Σ (Si × Pi). Note Q and S can be negative
   */
  function loadTotalAccountValue(address wallet, IndexPrice[] calldata indexPrices) external view returns (int64) {
    return
      Funding.loadTotalAccountValueIncludingOutstandingWalletFunding(
        Margin.LoadArguments(wallet, indexPrices, indexPriceCollectionServiceWallets),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsByBaseAssetSymbol
      );
  }

  /**
   * @notice Calculate total initial margin requirement with formula Σ abs(Si × Pi × Ii). Note S can be negative
   */
  function loadTotalInitialMarginRequirement(
    address wallet,
    IndexPrice[] calldata indexPrices
  ) external view returns (uint64) {
    return
      Margin.loadTotalInitialMarginRequirement(
        wallet,
        indexPrices,
        indexPriceCollectionServiceWallets,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
  }

  /**
   * @notice Calculate total maintenance margin requirement by formula Σ abs(Si × Pi × Mi). Note S can be negative
   */
  function loadTotalMaintenanceMarginRequirement(
    address wallet,
    IndexPrice[] calldata indexPrices
  ) external view returns (uint64) {
    return
      Margin.loadTotalMaintenanceMarginRequirement(
        wallet,
        indexPrices,
        indexPriceCollectionServiceWallets,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
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
    require(!walletExits[msg.sender].exists, "Wallet already exited");

    walletExits[msg.sender] = WalletExit(true, block.number + chainPropagationPeriodInBlocks);

    emit WalletExited(msg.sender, block.number + chainPropagationPeriodInBlocks);
  }

  /**
   * @notice Withdraw the entire balance of an asset for an exited wallet. The Chain Propagation
   * Period must have already passed since calling `exitWallet`
   *
   */
  function withdrawExit(address wallet) external {
    require(_isWalletExitFinalized(wallet), "Wallet exit not finalized");

    (uint256 exitFundPositionOpenedAtTimestampInMs, uint64 quantityInPips) = Withdrawing.withdrawExit(
      Withdrawing.WithdrawExitArguments(
        wallet,
        custodian,
        exitFundWallet,
        indexPriceCollectionServiceWallets,
        quoteAssetAddress
      ),
      exitFundPositionOpenedAtBlockNumber,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
    exitFundPositionOpenedAtBlockNumber = exitFundPositionOpenedAtTimestampInMs;

    emit WalletExitWithdrawn(wallet, quantityInPips);
  }

  /**
   * @notice Clears exited status of sending wallet. Upon mining immediately enables
   * deposits, trades, and withdrawals by sending wallet
   */
  function clearWalletExit() external {
    require(_isWalletExitFinalized(msg.sender), "Wallet exit not finalized");

    delete walletExits[msg.sender];

    emit WalletExitCleared(msg.sender);
  }

  function _isWalletExitFinalized(address wallet) internal view returns (bool) {
    WalletExit storage exit = walletExits[wallet];
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
    (uint64 timestampInMs, uint256 effectiveBlockNumber) = nonceInvalidationsByWallet.invalidateOrderNonce(
      nonce,
      chainPropagationPeriodInBlocks
    );

    emit OrderNonceInvalidated(msg.sender, nonce, timestampInMs, effectiveBlockNumber);
  }
}
