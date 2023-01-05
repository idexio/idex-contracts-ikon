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
import { MarketAdmin } from "./libraries/MarketAdmin.sol";
import { NonceInvalidations } from "./libraries/NonceInvalidations.sol";
import { NonMutatingMargin } from "./libraries/NonMutatingMargin.sol";
import { Owned } from "./Owned.sol";
import { PositionBelowMinimumLiquidation } from "./libraries/PositionBelowMinimumLiquidation.sol";
import { PositionInDeactivatedMarketLiquidation } from "./libraries/PositionInDeactivatedMarketLiquidation.sol";
import { String } from "./libraries/String.sol";
import { Trading } from "./libraries/Trading.sol";
import { WalletLiquidation } from "./libraries/WalletLiquidation.sol";
import { Withdrawing } from "./libraries/Withdrawing.sol";
import { AcquisitionDeleverageArguments, Balance, ClosureDeleverageArguments, ExecuteOrderBookTradeArguments, FundingMultiplierQuartet, IndexPrice, Market, MarketOverrides, NonceInvalidation, Order, OrderBookTrade, OverridableMarketFields, WalletLiquidationArguments, Withdrawal } from "./libraries/Structs.sol";
import { DeleverageType, LiquidationType, OrderSide } from "./libraries/Enums.sol";
import { ICustodian, IExchange } from "./libraries/Interfaces.sol";

// solhint-disable-next-line contract-name-camelcase
contract Exchange_v4 is IExchange, Owned {
  using BalanceTracking for BalanceTracking.Storage;
  using NonceInvalidations for mapping(address => NonceInvalidation[]);

  // Internally used structs //

  struct WalletExit {
    bool exists;
    uint256 effectiveBlockNumber;
  }

  // State variables //

  // Balance tracking
  BalanceTracking.Storage private _balanceTracking;
  // Mapping of wallet => list of base asset symbols with open positions
  mapping(address => string[]) private _baseAssetSymbolsWithOpenPositionsByWallet;
  // Mapping of order wallet hash => isComplete
  mapping(bytes32 => bool) private _completedOrderHashes;
  // Withdrawals - mapping of withdrawal wallet hash => isComplete
  mapping(bytes32 => bool) private _completedWithdrawalHashes;
  // Fund custody contract
  ICustodian public custodian;
  // Deposit index
  uint64 public depositIndex;
  // Zero only if Exit Fund has no open positions or quote balance
  uint256 private _exitFundPositionOpenedAtBlockNumber;
  // If positive (index increases) longs pay shorts; if negative (index decreases) shorts pay longs
  mapping(string => FundingMultiplierQuartet[]) public fundingMultipliersByBaseAssetSymbol;
  // Milliseconds since epoch, always aligned to funding period
  mapping(string => uint64) private _lastFundingRatePublishTimestampInMsByBaseAssetSymbol;
  // Wallet-specific market parameter overrides
  mapping(string => mapping(address => MarketOverrides)) public marketOverridesByBaseAssetSymbolAndWallet;
  // Markets
  mapping(string => Market) public marketsByBaseAssetSymbol;
  // Mapping of wallet => last invalidated timestampInMs
  mapping(address => NonceInvalidation[]) private _nonceInvalidationsByWallet;
  // Mapping of order hash => filled quantity in pips
  mapping(bytes32 => uint64) public partiallyFilledOrderQuantities;
  // Address of ERC20 contract used as collateral and quote for all markets
  address public immutable quoteAssetAddress;
  // Exits
  mapping(address => WalletExit) public walletExits;

  // State variables - tunable parameters //

  uint256 public chainPropagationPeriodInBlocks;
  uint64 public delegateKeyExpirationPeriodInMs;
  uint64 public positionBelowMinimumLiquidationPriceToleranceMultiplier;

  // State variables - tunable wallets //

  address public dispatcherWallet;
  address public exitFundWallet;
  address public feeWallet;
  // TODO Upgrade through Governance
  address[] public indexPriceCollectionServiceWallets;
  // TODO Upgrade through Governance
  address public insuranceFundWallet;

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
  event Deposited(uint64 index, address wallet, uint64 quantity, int64 newExchangeBalance);
  /**
   * @notice Emitted when a user invokes the Exit Wallet mechanism with `exitWallet`
   */
  event WalletExited(address wallet, uint256 effectiveBlockNumber);
  /**
   * @notice Emitted when a user withdraws an asset balance through the Exit Wallet mechanism with
   * `withdrawExit`
   */
  event WalletExitWithdrawn(address wallet, uint64 quantity);
  /**
   * @notice Emitted when a user clears the exited status of a wallet previously exited with
   * `clearWalletExit`
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
    uint64 baseQuantity,
    uint64 quoteQuantity,
    OrderSide takerSide
  );
  /**
   * @notice Emitted when a user invalidates an order nonce with `invalidateOrderNonce`
   */
  event OrderNonceInvalidated(address wallet, uint128 nonce, uint128 timestampInMs, uint256 effectiveBlockNumber);
  /**
   * @notice Emitted when the Dispatcher Wallet submits a withdrawal with `withdraw`
   */
  event Withdrawn(address wallet, uint64 quantity, int64 newExchangeBalance);

  // Modifiers //

  modifier onlyDispatcher() {
    require(msg.sender == dispatcherWallet, "Caller is not dispatcher");
    _;
  }

  // Functions //

  /**
   * @notice Instantiate a new `Exchange` contract
   *
   * @dev Sets `_balanceTracking.migrationSource` to first argument, and `owner_` and `admin_` to `msg.sender`
   */
  constructor(
    IExchange balanceMigrationSource,
    address quoteAssetAddress_,
    address exitFundWallet_,
    address feeWallet_,
    address insuranceFundWallet_,
    address[] memory indexPriceCollectionServiceWallets_
  ) Owned() {
    require(
      address(balanceMigrationSource) == address(0x0) || Address.isContract(address(balanceMigrationSource)),
      "Invalid migration source"
    );
    _balanceTracking.migrationSource = balanceMigrationSource;

    require(Address.isContract(address(quoteAssetAddress_)), "Invalid quote asset address");
    quoteAssetAddress = quoteAssetAddress_;

    setExitFundWallet(exitFundWallet_);

    setFeeWallet(feeWallet_);

    setInsuranceFundWallet(insuranceFundWallet_);

    for (uint8 i = 0; i < indexPriceCollectionServiceWallets_.length; i++) {
      require(address(indexPriceCollectionServiceWallets_[i]) != address(0x0), "Invalid IPCS wallet");
    }
    indexPriceCollectionServiceWallets = indexPriceCollectionServiceWallets_;

    // Deposits must be manually enabled via `setDepositIndex`
    depositIndex = Constants.DEPOSIT_INDEX_NOT_SET;
  }

  // Tunable parameters //

  /**
   * @notice Sets a new Chain Propagation Period - the block delay after which order nonce invalidations are respected
   * by `executeOrderBookTrade` and wallet exits are respected by `executeOrderBookTrade` and `withdraw`
   *
   * @param newChainPropagationPeriodInBlocks The new Chain Propagation Period expressed as a number of blocks. Must
   * be less than `Constants.MAX_CHAIN_PROPAGATION_PERIOD_IN_BLOCKS`
   */
  function setChainPropagationPeriod(uint256 newChainPropagationPeriodInBlocks) external onlyAdmin {
    require(
      newChainPropagationPeriodInBlocks <= Constants.MAX_CHAIN_PROPAGATION_PERIOD_IN_BLOCKS,
      "Must be less than max"
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
      newDelegateKeyExpirationPeriodInMs <= Constants.MAX_DELEGATE_KEY_EXPIRATION_PERIOD_IN_MS,
      "Must be less than max"
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
    require(
      newPositionBelowMinimumLiquidationPriceToleranceMultiplier <= Constants.MAX_FEE_MULTIPLIER,
      "Must be less than max"
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
   */
  function setDepositIndex() external onlyAdmin {
    require(depositIndex == Constants.DEPOSIT_INDEX_NOT_SET, "Can only be set once");

    depositIndex = address(_balanceTracking.migrationSource) == address(0x0)
      ? 0
      : _balanceTracking.migrationSource.depositIndex();
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

    require(
      !ExitFund.isExitFundPositionOrQuoteOpen(
        exitFundWallet,
        _balanceTracking,
        _baseAssetSymbolsWithOpenPositionsByWallet
      ),
      "EF cannot have open balance"
    );

    address oldExitFundWallet = exitFundWallet;
    exitFundWallet = newExitFundWallet;

    emit ExitFundWalletChanged(oldExitFundWallet, newExitFundWallet);
  }

  /**
   * @notice Sets the address of the Fee wallet
   *
   * @dev Trade and Withdraw fees will accrue in the `_balanceTracking` quote mapping for this wallet
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
   * @return The internal `Balance` struct tracking the asset at `assetSymbol` currently in an open position for or
   * deposited by `wallet`
   */
  function loadBalanceStructBySymbol(
    address wallet,
    string calldata assetSymbol
  ) external view override returns (Balance memory) {
    return _balanceTracking.loadBalanceStructFromMigrationSourceIfNeeded(wallet, assetSymbol);
  }

  /**
   * @notice Load a wallet's balance by asset symbol, in pips
   *
   * @param wallet The wallet address to load the balance for. Can be different from `msg.sender`
   * @param assetSymbol The asset symbol to load the wallet's balance for
   *
   * @return balance The quantity denominated in pips of asset at `assetSymbol` currently in an open position or
   * quote balance by `wallet` if base or quote respectively. Result may be negative
   */
  function loadBalanceBySymbol(
    address wallet,
    string calldata assetSymbol
  ) external view override returns (int64 balance) {
    balance = _balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, assetSymbol);

    if (String.isEqual(assetSymbol, Constants.QUOTE_ASSET_SYMBOL)) {
      balance += Funding.loadOutstandingWalletFunding_delegatecall(
        wallet,
        _balanceTracking,
        _baseAssetSymbolsWithOpenPositionsByWallet,
        fundingMultipliersByBaseAssetSymbol,
        _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsByBaseAssetSymbol
      );
    }
  }

  // Dispatcher whitelisting //

  /**
   * @notice Sets the wallet whitelisted to dispatch transactions calling the `executeOrderBookTrade` and `withdraw`
   * functions
   *
   * @param newDispatcherWallet The new whitelisted dispatcher wallet. Must be different from the current one
   */
  function setDispatcher(address newDispatcherWallet) external onlyAdmin {
    require(newDispatcherWallet != address(0x0), "Invalid wallet address");
    require(newDispatcherWallet != dispatcherWallet, "Must be different from current");
    dispatcherWallet = newDispatcherWallet;
  }

  /**
   * @notice Clears the currently set whitelisted dispatcher wallet, effectively disabling calling any functions
   * restricted by the `onlyDispatcher` modifier until a new wallet is set with `setDispatcher`
   */
  function removeDispatcher() external onlyAdmin {
    dispatcherWallet = address(0x0);
  }

  // Depositing //

  /**
   * @notice Deposit quote token
   *
   * @param quantityInAssetUnits The quantity to deposit. The sending wallet must first call the `approve` method on
   * the token contract for at least this quantity
   */
  function deposit(uint256 quantityInAssetUnits) external {
    // Deposits are disabled until `setDepositIndex` is called successfully
    require(depositIndex != Constants.DEPOSIT_INDEX_NOT_SET, "Deposits disabled");

    // Calling exitWallet disables deposits immediately on mining, in contrast to withdrawals and trades which respect
    // the Chain Propagation Period given by `effectiveBlockNumber` via `_isWalletExitFinalized`
    require(!walletExits[msg.sender].exists, "Wallet exited");

    (uint64 quantity, int64 newExchangeBalance) = Depositing.deposit_delegatecall(
      msg.sender,
      quantityInAssetUnits,
      quoteAssetAddress,
      custodian,
      _balanceTracking
    );

    depositIndex++;

    emit Deposited(depositIndex, msg.sender, quantity, newExchangeBalance);
  }

  // Trades //

  /**
   * @notice Settles a trade between two orders submitted and matched off-chain
   *
   * @param buy An `Order` struct encoding the parameters of the buy-side order (receiving base, giving quote)
   * @param sell An `Order` struct encoding the parameters of the sell-side order (giving base, receiving quote)
   * @param orderBookTrade An `OrderBookTrade` struct encoding the parameters of this trade execution of the two orders
   */
  function executeOrderBookTrade(
    Order calldata buy,
    Order calldata sell,
    OrderBookTrade calldata orderBookTrade,
    IndexPrice[] calldata buyWalletIndexPrices,
    IndexPrice[] calldata sellWalletIndexPrices
  ) external onlyDispatcher {
    require(!_isWalletExitFinalized(buy.wallet), "Buy wallet exit finalized");
    require(!_isWalletExitFinalized(sell.wallet), "Sell wallet exit finalized");

    Trading.executeOrderBookTrade_delegatecall(
      // We wrap the arguments in a struct to avoid 'Stack too deep' errors
      ExecuteOrderBookTradeArguments(
        buy,
        sell,
        orderBookTrade,
        buyWalletIndexPrices,
        sellWalletIndexPrices,
        delegateKeyExpirationPeriodInMs,
        exitFundWallet,
        feeWallet,
        insuranceFundWallet,
        indexPriceCollectionServiceWallets
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      _completedOrderHashes,
      fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol,
      _nonceInvalidationsByWallet,
      partiallyFilledOrderQuantities
    );

    emit OrderBookTradeExecuted(
      buy.wallet,
      sell.wallet,
      orderBookTrade.baseAssetSymbol,
      orderBookTrade.quoteAssetSymbol,
      orderBookTrade.baseQuantity,
      orderBookTrade.quoteQuantity,
      orderBookTrade.makerSide == OrderSide.Buy ? OrderSide.Sell : OrderSide.Buy
    );
  }

  // Liquidation //

  /**
   * @notice Liquidates a single position below the market's configured `minimumPositionSize` to the Insurance Fund
   * at the current index price
   */
  function liquidatePositionBelowMinimum(
    string calldata baseAssetSymbol,
    address liquidatingWallet,
    uint64 liquidationQuoteQuantity,
    IndexPrice[] calldata insuranceFundIndexPrices,
    IndexPrice[] calldata liquidatingWalletIndexPrices
  ) external onlyDispatcher {
    PositionBelowMinimumLiquidation.liquidate_delegatecall(
      PositionBelowMinimumLiquidation.Arguments(
        baseAssetSymbol,
        liquidatingWallet,
        liquidationQuoteQuantity,
        insuranceFundIndexPrices,
        liquidatingWalletIndexPrices,
        positionBelowMinimumLiquidationPriceToleranceMultiplier,
        insuranceFundWallet,
        indexPriceCollectionServiceWallets
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Liquidates a single position in a deactivated market at the previously set index price
   */
  function liquidatePositionInDeactivatedMarket(
    string calldata baseAssetSymbol,
    uint64 feeQuantity,
    address liquidatingWallet,
    uint64 liquidationQuoteQuantity,
    IndexPrice[] calldata liquidatingWalletIndexPrices
  ) external onlyDispatcher {
    PositionInDeactivatedMarketLiquidation.liquidate_delegatecall(
      PositionInDeactivatedMarketLiquidation.Arguments(
        baseAssetSymbol,
        feeQuantity,
        feeWallet,
        liquidatingWallet,
        liquidationQuoteQuantity,
        liquidatingWalletIndexPrices,
        indexPriceCollectionServiceWallets
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Liquidates all positions held by a wallet below maintenance requirements to the Insurance Fund at each
   * position's bankruptcy price
   */
  function liquidateWalletInMaintenance(
    WalletLiquidationArguments calldata liquidationArguments
  ) external onlyDispatcher {
    WalletLiquidation.liquidate_delegatecall(
      WalletLiquidation.Arguments(
        liquidationArguments,
        LiquidationType.WalletInMaintenance,
        exitFundWallet,
        insuranceFundWallet,
        indexPriceCollectionServiceWallets
      ),
      0,
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Liquidates all positions held by a wallet below maintenance requirements to the Exit Fund at each
   * position's bankruptcy price
   */
  function liquidateWalletInMaintenanceDuringSystemRecovery(
    WalletLiquidationArguments calldata liquidationArguments
  ) external onlyDispatcher {
    require(_exitFundPositionOpenedAtBlockNumber > 0, "Exit Fund has no positions");

    _exitFundPositionOpenedAtBlockNumber = WalletLiquidation.liquidate_delegatecall(
      WalletLiquidation.Arguments(
        liquidationArguments,
        LiquidationType.WalletInMaintenanceDuringSystemRecovery,
        exitFundWallet,
        insuranceFundWallet,
        indexPriceCollectionServiceWallets
      ),
      _exitFundPositionOpenedAtBlockNumber,
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Liquidates all positions of an exited wallet to the Insurance Fund at each position's exit price
   */
  function liquidateWalletExited(WalletLiquidationArguments calldata liquidationArguments) external onlyDispatcher {
    require(walletExits[liquidationArguments.liquidatingWallet].exists, "Wallet not exited");

    WalletLiquidation.liquidate_delegatecall(
      WalletLiquidation.Arguments(
        liquidationArguments,
        LiquidationType.WalletExited,
        exitFundWallet,
        insuranceFundWallet,
        indexPriceCollectionServiceWallets
      ),
      0,
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
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
    AcquisitionDeleverageArguments calldata deleverageArguments
  ) external onlyDispatcher {
    AcquisitionDeleveraging.deleverage_delegatecall(
      AcquisitionDeleveraging.Arguments(
        deleverageArguments,
        DeleverageType.WalletInMaintenance,
        exitFundWallet,
        insuranceFundWallet,
        indexPriceCollectionServiceWallets
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Reduces a single position held by the Insurance Fund by deleveraging a counterparty position at the entry
   * price of the Insurance Fund
   */
  function deleverageInsuranceFundClosure(
    ClosureDeleverageArguments calldata deleverageArguments
  ) external onlyDispatcher {
    ClosureDeleveraging.deleverage_delegatecall(
      ClosureDeleveraging.Arguments(
        deleverageArguments,
        DeleverageType.InsuranceFundClosure,
        exitFundWallet,
        insuranceFundWallet,
        indexPriceCollectionServiceWallets
      ),
      0,
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Reduces a single position held by an exited wallet by deleveraging a counterparty position at the exit
   * price of the liquidating wallet
   */
  function deleverageExitAcquisition(
    AcquisitionDeleverageArguments calldata deleverageArguments
  ) external onlyDispatcher {
    require(walletExits[deleverageArguments.liquidatingWallet].exists, "Wallet not exited");

    AcquisitionDeleveraging.deleverage_delegatecall(
      AcquisitionDeleveraging.Arguments(
        deleverageArguments,
        DeleverageType.WalletExited,
        exitFundWallet,
        insuranceFundWallet,
        indexPriceCollectionServiceWallets
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Reduces a single position held by the Exit Fund by deleveraging a counterparty position at the index
   * price or the Exit Fund's bankruptcy price if the Exit Fund account value is positive or negative, respectively
   */
  function deleverageExitFundClosure(ClosureDeleverageArguments calldata deleverageArguments) external onlyDispatcher {
    _exitFundPositionOpenedAtBlockNumber = ClosureDeleveraging.deleverage_delegatecall(
      ClosureDeleveraging.Arguments(
        deleverageArguments,
        DeleverageType.ExitFundClosure,
        exitFundWallet,
        insuranceFundWallet,
        indexPriceCollectionServiceWallets
      ),
      _exitFundPositionOpenedAtBlockNumber,
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
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

    int64 newExchangeBalance = Withdrawing.withdraw_delegatecall(
      Withdrawing.WithdrawArguments(
        withdrawal,
        indexPrices,
        quoteAssetAddress,
        custodian,
        _exitFundPositionOpenedAtBlockNumber,
        exitFundWallet,
        feeWallet,
        indexPriceCollectionServiceWallets
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      _completedWithdrawalHashes,
      fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    emit Withdrawn(withdrawal.wallet, withdrawal.grossQuantity, newExchangeBalance);
  }

  // Market management //

  function addMarket(Market calldata newMarket) external onlyAdmin {
    MarketAdmin.addMarket_delegatecall(newMarket, marketsByBaseAssetSymbol);
  }

  // TODO Update market

  function activateMarket(string calldata baseAssetSymbol) external onlyDispatcher {
    MarketAdmin.activateMarket_delegatecall(baseAssetSymbol, marketsByBaseAssetSymbol);
  }

  function deactivateMarket(string calldata baseAssetSymbol, IndexPrice memory indexPrice) external onlyDispatcher {
    MarketAdmin.deactivateMarket_delegatecall(
      baseAssetSymbol,
      indexPrice,
      indexPriceCollectionServiceWallets,
      marketsByBaseAssetSymbol
    );
  }

  // TODO Validations
  function setMarketOverrides(
    string calldata baseAssetSymbol,
    OverridableMarketFields calldata overridableFields,
    address wallet
  ) external onlyAdmin {
    MarketAdmin.setMarketOverrides_delegatecall(
      baseAssetSymbol,
      overridableFields,
      wallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  // Perps //

  /**
   * @notice Pushes fundingRate × indexPrice to fundingMultipliersByBaseAssetAddress mapping for market. Uses timestamp
   * component of index price to determine if funding rate is too recent after previously publish funding rate, and to
   * backfill empty values if a funding period was missed
   * TODO Validate funding rates
   */
  function publishFundingMutiplier(int64 fundingRate, IndexPrice calldata indexPrice) external onlyDispatcher {
    Funding.publishFundingMutiplier_delegatecall(
      fundingRate,
      indexPrice,
      indexPriceCollectionServiceWallets,
      fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Updates quote balance with historical funding payments for a market by walking funding multipliers
   * published since last position update up to max allowable by gas constraints
   */
  function updateWalletFundingForMarket(address wallet, string calldata baseAssetSymbol) public {
    Funding.updateWalletFundingForMarket_delegatecall(
      baseAssetSymbol,
      wallet,
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Calculate total outstanding funding payments
   */
  function loadOutstandingWalletFunding(address wallet) external view returns (int64) {
    return
      Funding.loadOutstandingWalletFunding_delegatecall(
        wallet,
        _balanceTracking,
        _baseAssetSymbolsWithOpenPositionsByWallet,
        fundingMultipliersByBaseAssetSymbol,
        _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsByBaseAssetSymbol
      );
  }

  /**
   * @notice Calculate total account value for a wallet by summing its quote asset balance and each open position's
   * notional values. Result may be negative
   *
   * @param wallet The wallet address to calculate total account value for
   * @param indexPrices If empty, position notional values will be calculated from on-chain price feed instead
   */
  function loadTotalAccountValue(address wallet, IndexPrice[] calldata indexPrices) external view returns (int64) {
    return
      Funding.loadTotalAccountValueIncludingOutstandingWalletFunding_delegatecall(
        NonMutatingMargin.LoadArguments(wallet, indexPrices, indexPriceCollectionServiceWallets),
        _balanceTracking,
        _baseAssetSymbolsWithOpenPositionsByWallet,
        fundingMultipliersByBaseAssetSymbol,
        _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsByBaseAssetSymbol
      );
  }

  /**
   * @notice Calculate total initial margin requirement for a wallet by summing each open position's initial margin
   * requirement
   *
   * @param wallet The wallet address to calculate total initial margin requirement for
   * @param indexPrices If empty, position notional values will be calculated from on-chain price feed instead
   */
  function loadTotalInitialMarginRequirement(
    address wallet,
    IndexPrice[] calldata indexPrices
  ) external view returns (uint64) {
    return
      NonMutatingMargin.loadTotalInitialMarginRequirement_delegatecall(
        wallet,
        indexPrices,
        indexPriceCollectionServiceWallets,
        _balanceTracking,
        _baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
  }

  /**
   * @notice Calculate total maintenence margin requirement for a wallet by summing each open position's maintanence
   * margin requirement as calculated from provided index prices
   *
   * @param wallet The wallet address to calculate total maintanence margin requirement for
   * @param indexPrices If empty, position notional values will be calculated from on-chain price feed instead
   */
  function loadTotalMaintenanceMarginRequirement(
    address wallet,
    IndexPrice[] calldata indexPrices
  ) external view returns (uint64) {
    return
      NonMutatingMargin.loadTotalMaintenanceMarginRequirement_delegatecall(
        wallet,
        indexPrices,
        indexPriceCollectionServiceWallets,
        _balanceTracking,
        _baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
  }

  // Wallet exits //

  /**
   * @notice Flags the sending wallet as exited, immediately disabling deposits upon mining. After the Chain Propagation
   * Period passes trades and withdrawals are also disabled for the wallet, and quote asset may then be withdrawn via
   * `withdrawExit`
   */
  function exitWallet() external {
    require(!walletExits[msg.sender].exists, "Wallet already exited");

    walletExits[msg.sender] = WalletExit(true, block.number + chainPropagationPeriodInBlocks);

    emit WalletExited(msg.sender, block.number + chainPropagationPeriodInBlocks);
  }

  /**
   * @notice Close all open positions and withdraw the net quote balance for an exited wallet. The Chain Propagation
   * Period must have already passed since calling `exitWallet`
   */
  function withdrawExit(address wallet) external {
    require(_isWalletExitFinalized(wallet), "Wallet exit not finalized");

    (uint256 exitFundPositionOpenedAtBlockNumber, uint64 quantity) = Withdrawing.withdrawExit_delegatecall(
      Withdrawing.WithdrawExitArguments(
        wallet,
        custodian,
        exitFundWallet,
        indexPriceCollectionServiceWallets,
        quoteAssetAddress
      ),
      _exitFundPositionOpenedAtBlockNumber,
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      _lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
    _exitFundPositionOpenedAtBlockNumber = exitFundPositionOpenedAtBlockNumber;

    emit WalletExitWithdrawn(wallet, quantity);
  }

  /**
   * @notice Clears exited status of sending wallet. Upon mining immediately enables deposits, trades, and withdrawals
   * by sending wallet
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
   * @param nonce A Version 1 UUID. After calling and once the Chain Propagation Period has elapsed,
   * `executeOrderBookTrade` will reject order nonces from this wallet with a timestampInMs component lower than the one
   * provided
   */
  function invalidateOrderNonce(uint128 nonce) external {
    (uint64 timestampInMs, uint256 effectiveBlockNumber) = _nonceInvalidationsByWallet.invalidateOrderNonce(
      nonce,
      chainPropagationPeriodInBlocks
    );

    emit OrderNonceInvalidated(msg.sender, nonce, timestampInMs, effectiveBlockNumber);
  }
}
