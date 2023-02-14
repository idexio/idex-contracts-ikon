// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { AcquisitionDeleveraging } from "./libraries/AcquisitionDeleveraging.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { AssetUnitConversions } from "./libraries/AssetUnitConversions.sol";
import { BalanceTracking } from "./libraries/BalanceTracking.sol";
import { ClosureDeleveraging } from "./libraries/ClosureDeleveraging.sol";
import { Constants } from "./libraries/Constants.sol";
import { Depositing } from "./libraries/Depositing.sol";
import { Exiting } from "./libraries/Exiting.sol";
import { ExitFund } from "./libraries/ExitFund.sol";
import { Funding } from "./libraries/Funding.sol";
import { Hashing } from "./libraries/Hashing.sol";
import { FieldUpgradeGovernance } from "./libraries/FieldUpgradeGovernance.sol";
import { Margin } from "./libraries/Margin.sol";
import { MarketAdmin } from "./libraries/MarketAdmin.sol";
import { NonceInvalidations } from "./libraries/NonceInvalidations.sol";
import { Owned } from "./Owned.sol";
import { PositionBelowMinimumLiquidation } from "./libraries/PositionBelowMinimumLiquidation.sol";
import { PositionInDeactivatedMarketLiquidation } from "./libraries/PositionInDeactivatedMarketLiquidation.sol";
import { String } from "./libraries/String.sol";
import { Trading } from "./libraries/Trading.sol";
import { Transferring } from "./libraries/Transferring.sol";
import { WalletLiquidation } from "./libraries/WalletLiquidation.sol";
import { Withdrawing } from "./libraries/Withdrawing.sol";
import { AcquisitionDeleverageArguments, Balance, ClosureDeleverageArguments, ExecuteOrderBookTradeArguments, FundingMultiplierQuartet, IndexPrice, Market, MarketOverrides, NonceInvalidation, Order, OrderBookTrade, OverridableMarketFields, PositionBelowMinimumLiquidationArguments, PositionInDeactivatedMarketLiquidationArguments, Transfer, WalletLiquidationArguments, Withdrawal } from "./libraries/Structs.sol";
import { DeleverageType, LiquidationType, OrderSide } from "./libraries/Enums.sol";
import { ICustodian, IExchange } from "./libraries/Interfaces.sol";

// solhint-disable-next-line contract-name-camelcase
contract Exchange_v4 is IExchange, Owned {
  using BalanceTracking for BalanceTracking.Storage;
  using FieldUpgradeGovernance for FieldUpgradeGovernance.Storage;
  using NonceInvalidations for mapping(address => NonceInvalidation[]);

  // State variables //

  // Balance tracking
  BalanceTracking.Storage private _balanceTracking;
  // Mapping of wallet => list of base asset symbols with open positions
  mapping(address => string[]) private _baseAssetSymbolsWithOpenPositionsByWallet;
  // Mapping of order wallet hash => isComplete
  mapping(bytes32 => bool) private _completedOrderHashes;
  // Transfers - mapping of transfer wallet hash => isComplete
  mapping(bytes32 => bool) private _completedTransferHashes;
  // Withdrawals - mapping of withdrawal wallet hash => isComplete
  mapping(bytes32 => bool) private _completedWithdrawalHashes;
  // In-progress IF wallet upgrade
  FieldUpgradeGovernance.Storage private _fieldUpgradeGovernance;
  // Fund custody contract
  ICustodian public custodian;
  // Deposit index
  uint64 public depositIndex;
  // Zero only if Exit Fund has no open positions or quote balance
  uint256 private _exitFundPositionOpenedAtBlockNumber;
  // If positive (index increases) longs pay shorts; if negative (index decreases) shorts pay longs
  mapping(string => FundingMultiplierQuartet[]) public fundingMultipliersByBaseAssetSymbol;
  // Milliseconds since epoch, always aligned to funding period
  mapping(string => uint64) public lastFundingRatePublishTimestampInMsByBaseAssetSymbol;
  // Wallet-specific market parameter overrides
  mapping(string => mapping(address => MarketOverrides)) private _marketOverridesByBaseAssetSymbolAndWallet;
  // Mapping of base asset symbol => market struct
  mapping(string => Market) private _marketsByBaseAssetSymbol;
  // Mapping of wallet => last invalidated timestampInMs
  mapping(address => NonceInvalidation[]) public nonceInvalidationsByWallet;
  // Mapping of order hash => filled quantity in pips
  mapping(bytes32 => uint64) private _partiallyFilledOrderQuantities;
  // Address of ERC20 contract used as collateral and quote for all markets
  address public immutable quoteAssetAddress;
  // Exits
  mapping(address => Exiting.WalletExit) private _walletExits;

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
   * @notice Emitted when a user deposits quote tokens with `deposit`
   */
  event Deposited(uint64 index, address wallet, uint64 quantity, int64 newExchangeBalance);
  /**
   * @notice Emitted when an admin changes the Exit Fund Wallet tunable parameter with `setExitFundWallet`
   */
  event ExitFundWalletChanged(address previousValue, address newValue);
  /**
   * @notice Emitted when an admin changes the Fee Wallet tunable parameter with `setFeeWallet`
   */
  event FeeWalletChanged(address previousValue, address newValue);
  /**
   * @notice Emitted when the Dispatch Wallet publishes a new funding rate with `publishFundingMutiplier`
   */
  event FundingRatePublished(string baseAssetSymbol, int64 fundingRate);
  /**
   * @notice Emitted when admin initiates IPCS wallet upgrade of with `initiateIndexPriceCollectionServiceWalletsUpgrade`
   */
  event IndexPriceCollectionServiceWalletsUpgradeInitiated(
    address[] oldIndexPriceCollectionServiceWallets,
    address[] newIndexPriceCollectionServiceWallets,
    uint256 blockThreshold
  );
  /**
   * @notice Emitted when admin cancels previously started IPCS wallet upgrade with `cancelIndexPriceCollectionServiceWalletsUpgrade`
   */
  event IndexPriceCollectionServiceWalletsUpgradeCanceled(
    address[] oldIndexPriceCollectionServiceWalletsWallet,
    address[] newIndexPriceCollectionServiceWalletsWallet
  );
  /**
   * @notice Emitted when admin finalizes IF wallet upgrade with `finalizeIndexPriceCollectionServiceWalletsUpgrade`
   */
  event IndexPriceCollectionServiceWalletsUpgradeFinalized(
    address[] oldIndexPriceCollectionServiceWalletsWallet,
    address[] newIndexPriceCollectionServiceWalletsWallet
  );
  /**
   * @notice Emitted when admin initiates IF wallet upgrade of with `initiateInsuranceFundWalletUpgrade`
   */
  event InsuranceFundWalletUpgradeInitiated(
    address oldInsuranceFundWallet,
    address newInsuranceFundWallet,
    uint256 blockThreshold
  );
  /**
   * @notice Emitted when admin cancels previously started IF wallet upgrade with `cancelInsuranceFundWalletUpgrade`
   */
  event InsuranceFundWalletUpgradeCanceled(address oldInsuranceFundWallet, address newInsuranceFundWallet);
  /**
   * @notice Emitted when admin finalizes IF wallet upgrade with `finalizeInsuranceFundWalletUpgrade`
   */
  event InsuranceFundWalletUpgradeFinalized(address oldInsuranceFundWallet, address newInsuranceFundWallet);
  /**
   * @notice Emitted when admin initiates market override upgrade with `initiateMarketOverridesUpgrade`
   */
  event MarketOverridesUpgradeInitiated(string baseAssetSymbol, address wallet, uint256 blockThreshold);
  /**
   * @notice Emitted when admin cancels previously started market override upgrade with `cancelMarketOverridesUpgrade`
   */
  event MarketOverridesUpgradeCanceled(string baseAssetSymbol, address wallet);
  /**
   * @notice Emitted when admin finalizes market override upgrade with `finalizeMarketOverridesUpgrade`
   */
  event MarketOverridesUpgradeFinalized(string baseAssetSymbol, address wallet);
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
   * @notice Emitted when an admin changes the position below minimum liquidation price tolerance tunable parameter
   * with `setPositionBelowMinimumLiquidationPriceToleranceMultiplier`
   */
  event PositionBelowMinimumLiquidationPriceToleranceMultiplierChanged(uint256 previousValue, uint256 newValue);
  /**
   * @notice Emitted when the Dispatcher Wallet submits a transfer with `transfer`
   */
  event Transferred(
    address sourceWallet,
    address destinationWallet,
    uint64 quantity,
    int64 newSourceWalletExchangeBalance
  );
  /**
   * @notice Emitted when a user clears the exited status of a wallet previously exited with
   * `clearWalletExit`
   */
  event WalletExitCleared(address wallet);
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

    require(insuranceFundWallet_ != address(0x0), "Invalid IF wallet address");
    insuranceFundWallet = insuranceFundWallet_;

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
   * @notice Initiates Index Price Collection Service wallet upgrade proccess. Once block delay has passed the process
   * can be finalized with `finalizeIndexPriceCollectionServiceWalletsUpgrade`
   *
   * @param newIndexPriceCollectionServiceWallets The IPCS wallet addresses
   */
  function initiateIndexPriceCollectionServiceWalletsUpgrade(
    address[] memory newIndexPriceCollectionServiceWallets
  ) external onlyAdmin {
    _fieldUpgradeGovernance.initiateIndexPriceCollectionServiceWalletsUpgrade_delegatecall(
      newIndexPriceCollectionServiceWallets
    );

    emit IndexPriceCollectionServiceWalletsUpgradeInitiated(
      indexPriceCollectionServiceWallets,
      newIndexPriceCollectionServiceWallets,
      _fieldUpgradeGovernance.currentIndexPriceCollectionServiceWalletsUpgrade.blockThreshold
    );
  }

  /**
   * @notice Cancels an in-flight IPCS wallet upgrade that has not yet been finalized
   */
  function cancelIndexPriceCollectionServiceWalletsUpgrade() external onlyAdmin {
    address[] memory newIndexPriceCollectionServiceWallets = _fieldUpgradeGovernance
      .cancelIndexPriceCollectionServiceWalletsUpgrade_delegatecall();

    emit IndexPriceCollectionServiceWalletsUpgradeCanceled(
      indexPriceCollectionServiceWallets,
      newIndexPriceCollectionServiceWallets
    );
  }

  /**
   * @notice Finalizes the IPCS wallet upgrade. The number of blocks specified by
   * `Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS` must have passed since calling
   * `initiateIndexPriceCollectionServiceWalletsUpgrade`
   *
   * @param newIndexPriceCollectionServiceWallets The address of the new IPCS wallets. Must equal the addresses
   * provided to `initiateIndexPriceCollectionServiceWalletsUpgrade`
   */
  function finalizeIndexPriceCollectionServiceWalletsUpgrade(
    address[] memory newIndexPriceCollectionServiceWallets
  ) external onlyAdmin {
    _fieldUpgradeGovernance.finalizeIndexPriceCollectionServiceWalletsUpgrade_delegatecall(
      newIndexPriceCollectionServiceWallets
    );

    address[] memory oldIndexPriceCollectionServiceWallets = indexPriceCollectionServiceWallets;
    indexPriceCollectionServiceWallets = newIndexPriceCollectionServiceWallets;

    emit IndexPriceCollectionServiceWalletsUpgradeFinalized(
      oldIndexPriceCollectionServiceWallets,
      newIndexPriceCollectionServiceWallets
    );
  }

  /**
   * @notice Initiates Insurance Fund wallet upgrade proccess. Once block delay has passed
   * the process can be finalized with `finalizeInsuranceFundWalletUpgrade`
   *
   * @param newInsuranceFundWallet The IF wallet address
   */
  function initiateInsuranceFundWalletUpgrade(address newInsuranceFundWallet) external onlyAdmin {
    _fieldUpgradeGovernance.initiateInsuranceFundWalletUpgrade_delegatecall(
      insuranceFundWallet,
      newInsuranceFundWallet
    );

    emit InsuranceFundWalletUpgradeInitiated(
      insuranceFundWallet,
      newInsuranceFundWallet,
      _fieldUpgradeGovernance.currentInsuranceFundWalletUpgrade.blockThreshold
    );
  }

  /**
   * @notice Cancels an in-flight IF wallet upgrade that has not yet been finalized
   */
  function cancelInsuranceFundWalletUpgrade() external onlyAdmin {
    address newInsuranceFundWallet = _fieldUpgradeGovernance.cancelInsuranceFundWalletUpgrade_delegatecall();

    emit InsuranceFundWalletUpgradeCanceled(insuranceFundWallet, newInsuranceFundWallet);
  }

  /**
   * @notice Finalizes the IF wallet upgrade. The number of blocks specified by
   * `Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS` must have passed since calling `initiateInsuranceFundWalletUpgrade`
   *
   * @param newInsuranceFundWallet The address of the new IF wallet. Must equal the address provided to
   * `initiateInsuranceFundWalletUpgrade`
   */
  function finalizeInsuranceFundWalletUpgrade(address newInsuranceFundWallet) external onlyAdmin {
    _fieldUpgradeGovernance.finalizeInsuranceFundWalletUpgrade_delegatecall(newInsuranceFundWallet);

    address oldInsuranceFundWallet = insuranceFundWallet;
    insuranceFundWallet = newInsuranceFundWallet;

    emit InsuranceFundWalletUpgradeFinalized(oldInsuranceFundWallet, newInsuranceFundWallet);
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
    string memory assetSymbol
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
    string memory assetSymbol
  ) external view override returns (int64 balance) {
    balance = _balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, assetSymbol);

    if (String.isEqual(assetSymbol, Constants.QUOTE_ASSET_SYMBOL)) {
      balance += Funding.loadOutstandingWalletFunding_delegatecall(
        wallet,
        _balanceTracking,
        _baseAssetSymbolsWithOpenPositionsByWallet,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        _marketsByBaseAssetSymbol
      );
    }
  }

  /**
   * @notice Load the balance of quote asset the wallet can withdraw after exiting, in pips
   *
   * @param wallet The wallet address to load the exit quote balance for. Can be different from `msg.sender`
   *
   * @return balance The quantity denominated in pips of quote asset that can be withdrawn after exiting the wallet.
   * Result may be zero, in which case an exit withdrawal would not transfer out any quote but would still close all
   * positions and quote balance
   */
  function loadQuoteQuantityAvailableForExitWithdrawal(address wallet) external view returns (uint64) {
    return
      Margin.loadQuoteQuantityAvailableForExitWithdrawal_delegatecall(
        wallet,
        _balanceTracking,
        _baseAssetSymbolsWithOpenPositionsByWallet,
        _marketOverridesByBaseAssetSymbolAndWallet,
        _marketsByBaseAssetSymbol
      );
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
    (uint64 quantity, int64 newExchangeBalance) = Depositing.deposit_delegatecall(
      custodian,
      depositIndex,
      quantityInAssetUnits,
      quoteAssetAddress,
      msg.sender,
      _balanceTracking,
      _walletExits
    );

    depositIndex++;

    emit Deposited(depositIndex, msg.sender, quantity, newExchangeBalance);
  }

  // Trades //

  /**
   * @notice Settles a trade between two orders submitted and matched off-chain
   *
   * @param tradeArguments An `ExecuteOrderBookTradeArguments` struct encoding the buy order, sell order, and trade
   * execution parameters
   */
  function executeOrderBookTrade(ExecuteOrderBookTradeArguments memory tradeArguments) external onlyDispatcher {
    Trading.executeOrderBookTrade_delegatecall(
      Trading.Arguments(
        tradeArguments,
        delegateKeyExpirationPeriodInMs,
        exitFundWallet,
        feeWallet,
        insuranceFundWallet,
        new bytes(0)
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      _completedOrderHashes,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol,
      nonceInvalidationsByWallet,
      _partiallyFilledOrderQuantities,
      _walletExits
    );

    emit OrderBookTradeExecuted(
      tradeArguments.buy.wallet,
      tradeArguments.sell.wallet,
      tradeArguments.orderBookTrade.baseAssetSymbol,
      tradeArguments.orderBookTrade.quoteAssetSymbol,
      tradeArguments.orderBookTrade.baseQuantity,
      tradeArguments.orderBookTrade.quoteQuantity,
      tradeArguments.orderBookTrade.makerSide == OrderSide.Buy ? OrderSide.Sell : OrderSide.Buy
    );
  }

  // Liquidation //

  /**
   * @notice Liquidates a single position below the market's configured `minimumPositionSize` to the Insurance Fund
   * at the current index price
   */
  function liquidatePositionBelowMinimum(
    PositionBelowMinimumLiquidationArguments memory liquidationArguments
  ) external onlyDispatcher {
    PositionBelowMinimumLiquidation.liquidate_delegatecall(
      PositionBelowMinimumLiquidation.Arguments(
        liquidationArguments,
        positionBelowMinimumLiquidationPriceToleranceMultiplier,
        insuranceFundWallet
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Liquidates a single position in a deactivated market at the previously set index price
   */
  function liquidatePositionInDeactivatedMarket(
    PositionInDeactivatedMarketLiquidationArguments memory liquidationArguments
  ) external onlyDispatcher {
    PositionInDeactivatedMarketLiquidation.liquidate_delegatecall(
      liquidationArguments,
      feeWallet,
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Liquidates all positions held by a wallet below maintenance requirements to the Insurance Fund at each
   * position's bankruptcy price
   */
  function liquidateWalletInMaintenance(
    WalletLiquidationArguments memory liquidationArguments
  ) external onlyDispatcher {
    WalletLiquidation.liquidate_delegatecall(
      WalletLiquidation.Arguments(
        liquidationArguments,
        LiquidationType.WalletInMaintenance,
        exitFundWallet,
        insuranceFundWallet
      ),
      0,
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Liquidates all positions held by a wallet below maintenance requirements to the Exit Fund at each
   * position's bankruptcy price
   */
  function liquidateWalletInMaintenanceDuringSystemRecovery(
    WalletLiquidationArguments memory liquidationArguments
  ) external onlyDispatcher {
    require(_exitFundPositionOpenedAtBlockNumber > 0, "Exit Fund has no positions");

    _exitFundPositionOpenedAtBlockNumber = WalletLiquidation.liquidate_delegatecall(
      WalletLiquidation.Arguments(
        liquidationArguments,
        LiquidationType.WalletInMaintenanceDuringSystemRecovery,
        exitFundWallet,
        insuranceFundWallet
      ),
      _exitFundPositionOpenedAtBlockNumber,
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Liquidates all positions of an exited wallet to the Insurance Fund at each position's exit price
   */
  function liquidateWalletExited(WalletLiquidationArguments memory liquidationArguments) external onlyDispatcher {
    require(_walletExits[liquidationArguments.liquidatingWallet].exists, "Wallet not exited");

    WalletLiquidation.liquidate_delegatecall(
      WalletLiquidation.Arguments(
        liquidationArguments,
        LiquidationType.WalletExited,
        exitFundWallet,
        insuranceFundWallet
      ),
      0,
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
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
    AcquisitionDeleverageArguments memory deleverageArguments
  ) external onlyDispatcher {
    AcquisitionDeleveraging.deleverage_delegatecall(
      AcquisitionDeleveraging.Arguments(
        deleverageArguments,
        DeleverageType.WalletInMaintenance,
        exitFundWallet,
        insuranceFundWallet
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Reduces a single position held by the Insurance Fund by deleveraging a counterparty position at the entry
   * price of the Insurance Fund
   */
  function deleverageInsuranceFundClosure(
    ClosureDeleverageArguments memory deleverageArguments
  ) external onlyDispatcher {
    ClosureDeleveraging.deleverage_delegatecall(
      ClosureDeleveraging.Arguments(
        deleverageArguments,
        DeleverageType.InsuranceFundClosure,
        exitFundWallet,
        insuranceFundWallet
      ),
      0,
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Reduces a single position held by an exited wallet by deleveraging a counterparty position at the exit
   * price of the liquidating wallet
   */
  function deleverageExitAcquisition(
    AcquisitionDeleverageArguments memory deleverageArguments
  ) external onlyDispatcher {
    require(_walletExits[deleverageArguments.liquidatingWallet].exists, "Wallet not exited");

    AcquisitionDeleveraging.deleverage_delegatecall(
      AcquisitionDeleveraging.Arguments(
        deleverageArguments,
        DeleverageType.WalletExited,
        exitFundWallet,
        insuranceFundWallet
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Reduces a single position held by the Exit Fund by deleveraging a counterparty position at the index
   * price or the Exit Fund's bankruptcy price if the Exit Fund account value is positive or negative, respectively
   */
  function deleverageExitFundClosure(ClosureDeleverageArguments memory deleverageArguments) external onlyDispatcher {
    _exitFundPositionOpenedAtBlockNumber = ClosureDeleveraging.deleverage_delegatecall(
      ClosureDeleveraging.Arguments(
        deleverageArguments,
        DeleverageType.ExitFundClosure,
        exitFundWallet,
        insuranceFundWallet
      ),
      _exitFundPositionOpenedAtBlockNumber,
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );
  }

  // Transfers //

  function transfer(Transfer memory transfer_) public onlyDispatcher {
    int64 newSourceWalletExchangeBalance = Transferring.transfer_delegatecall(
      Transferring.Arguments(transfer_, exitFundWallet, insuranceFundWallet, feeWallet),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      _completedTransferHashes,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol,
      _walletExits
    );

    emit Transferred(
      transfer_.sourceWallet,
      transfer_.destinationWallet,
      transfer_.grossQuantity,
      newSourceWalletExchangeBalance
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
    require(!Exiting.isWalletExitFinalized(withdrawal.wallet, _walletExits), "Wallet exited");

    int64 newExchangeBalance = Withdrawing.withdraw_delegatecall(
      Withdrawing.WithdrawArguments(
        withdrawal,
        quoteAssetAddress,
        custodian,
        _exitFundPositionOpenedAtBlockNumber,
        exitFundWallet,
        feeWallet
      ),
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      _completedWithdrawalHashes,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );

    emit Withdrawn(withdrawal.wallet, withdrawal.grossQuantity, newExchangeBalance);
  }

  // Market management //

  /**
   * @notice Create a new market that will initially be deactivated. Funding multipliers will be backfilled with zero
   * values for the current day UTC. Note this may block publishing new funding multipliers for up to half the funding
   * period interval following market creation
   */
  function addMarket(Market memory newMarket) external onlyAdmin {
    MarketAdmin.addMarket_delegatecall(
      newMarket,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Activate a market, which allows positions to be opened and funding payments made
   */
  function activateMarket(string memory baseAssetSymbol) external onlyDispatcher {
    MarketAdmin.activateMarket_delegatecall(baseAssetSymbol, _marketsByBaseAssetSymbol);
  }

  /**
   * @notice Deactivate a market
   */
  function deactivateMarket(string memory baseAssetSymbol) external onlyDispatcher {
    MarketAdmin.deactivateMarket_delegatecall(baseAssetSymbol, _marketsByBaseAssetSymbol);
  }

  /**
   * @notice Publish updated index prices for markets
   */
  function publishIndexPrices(IndexPrice[] memory indexPrices) external onlyDispatcher {
    MarketAdmin.publishIndexPrices_delegatecall(
      indexPrices,
      indexPriceCollectionServiceWallets,
      _marketsByBaseAssetSymbol
    );
  }

  /**
   * @notice Initiates market override upgrade proccess for `wallet`. If `wallet` is zero address, then the overrides
   * will become the new default values for the market. Once `Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS` has passed the
   * process can be finalized with `finalizeMarketOverridesUpgrade`
   */
  function initiateMarketOverridesUpgrade(
    string memory baseAssetSymbol,
    OverridableMarketFields memory overridableFields,
    address wallet
  ) external onlyAdmin {
    uint256 blockThreshold = MarketAdmin.initiateMarketOverridesUpgrade_delegatecall(
      baseAssetSymbol,
      overridableFields,
      wallet,
      _fieldUpgradeGovernance,
      _marketsByBaseAssetSymbol
    );

    emit MarketOverridesUpgradeInitiated(baseAssetSymbol, wallet, blockThreshold);
  }

  /**
   * @notice Cancels an in-flight market override upgrade process that has not yet been finalized
   */
  function cancelMarketOverridesUpgrade(string memory baseAssetSymbol, address wallet) external onlyAdmin {
    MarketAdmin.cancelMarketOverridesUpgrade_delegatecall(baseAssetSymbol, wallet, _fieldUpgradeGovernance);

    emit MarketOverridesUpgradeCanceled(baseAssetSymbol, wallet);
  }

  /**
   * @notice Finalizes a market override upgrade process by changing the market's default overridable field values if
   * `wallet` is the zero address, or assigning wallet-specific overrides otherwise. The number of blocks specified by
   * `Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS` must have passed since calling `initiateMarketOverridesUpgrade`
   */
  function finalizeMarketOverridesUpgrade(string memory baseAssetSymbol, address wallet) external onlyAdmin {
    MarketAdmin.finalizeMarketOverridesUpgrade_delegatecall(
      baseAssetSymbol,
      wallet,
      _fieldUpgradeGovernance,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol
    );

    emit MarketOverridesUpgradeFinalized(baseAssetSymbol, wallet);
  }

  /**
   * @notice Sends tokens mistakenly sent directly to the `Exchange` to the fee wallet (the abscence of a `receive`
   * function rejects incoming native asset transfers)
   */
  function skim(address tokenAddress) external onlyAdmin {
    Withdrawing.skim_delegatecall(tokenAddress, feeWallet);
  }

  // Perps //

  /**
   * @notice Pushes fundingRate × indexPrice to fundingMultipliersByBaseAssetAddress mapping for market. Uses timestamp
   * component of index price to determine if funding rate is too recent after previously publish funding rate, and to
   * backfill empty values if a funding period was missed
   */
  function publishFundingMultiplier(string memory baseAssetSymbol, int64 fundingRate) external onlyDispatcher {
    Funding.publishFundingMultiplier_delegatecall(
      baseAssetSymbol,
      fundingRate,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketsByBaseAssetSymbol
    );

    emit FundingRatePublished(baseAssetSymbol, fundingRate);
  }

  /**
   * @notice Updates quote balance with historical funding payments for a market by walking funding multipliers
   * published since last position update up to max allowable by gas constraints
   */
  function updateWalletFundingForMarket(address wallet, string memory baseAssetSymbol) public {
    Funding.updateWalletFundingForMarket_delegatecall(
      baseAssetSymbol,
      wallet,
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketsByBaseAssetSymbol
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
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        _marketsByBaseAssetSymbol
      );
  }

  /**
   * @notice Calculate total account value for a wallet by summing its quote asset balance and each open position's
   * notional values as computed by latest published index price. Result may be negative
   *
   * @param wallet The wallet address to calculate total account value for
   */
  function loadTotalAccountValue(address wallet) external view returns (int64) {
    return
      Funding.loadTotalAccountValueIncludingOutstandingWalletFunding_delegatecall(
        wallet,
        _balanceTracking,
        _baseAssetSymbolsWithOpenPositionsByWallet,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        _marketsByBaseAssetSymbol
      );
  }

  /**
   * @notice Calculate total account value for a wallet by summing its quote asset balance and each open position's
   * notional values as computed by on-chain feed price. Result may be negative
   *
   * @param wallet The wallet address to calculate total account value for
   */
  function loadTotalAccountValueFromOnChainPriceFeed(address wallet) external view returns (int64) {
    return
      Funding.loadTotalAccountValueIncludingOutstandingWalletFundingFromOnChainPriceFeed_delegatecall(
        wallet,
        _balanceTracking,
        _baseAssetSymbolsWithOpenPositionsByWallet,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        _marketsByBaseAssetSymbol
      );
  }

  /**
   * @notice Calculate total initial margin requirement for a wallet by summing each open position's initial margin
   * requirement as computed by latest published index price
   *
   * @param wallet The wallet address to calculate total initial margin requirement for
   */
  function loadTotalInitialMarginRequirement(address wallet) external view returns (uint64) {
    return
      Margin.loadTotalInitialMarginRequirement_delegatecall(
        wallet,
        _balanceTracking,
        _baseAssetSymbolsWithOpenPositionsByWallet,
        _marketOverridesByBaseAssetSymbolAndWallet,
        _marketsByBaseAssetSymbol
      );
  }

  /**
   * @notice Calculate total initial margin requirement for a wallet by summing each open position's initial margin
   * requirement as computed by on-chain feed price
   *
   * @param wallet The wallet address to calculate total initial margin requirement for
   */
  function loadTotalInitialMarginRequirementFromOnChainPriceFeed(address wallet) external view returns (uint64) {
    return
      Margin.loadTotalInitialMarginRequirementFromOnChainPriceFeed_delegatecall(
        wallet,
        _balanceTracking,
        _baseAssetSymbolsWithOpenPositionsByWallet,
        _marketOverridesByBaseAssetSymbolAndWallet,
        _marketsByBaseAssetSymbol
      );
  }

  /**
   * @notice Calculate total maintenence margin requirement for a wallet by summing each open position's maintanence
   * margin requirement as computed by latest published index price
   *
   * @param wallet The wallet address to calculate total maintanence margin requirement for
   */
  function loadTotalMaintenanceMarginRequirement(address wallet) external view returns (uint64) {
    return
      Margin.loadTotalMaintenanceMarginRequirement_delegatecall(
        wallet,
        _balanceTracking,
        _baseAssetSymbolsWithOpenPositionsByWallet,
        _marketOverridesByBaseAssetSymbolAndWallet,
        _marketsByBaseAssetSymbol
      );
  }

  /**
   * @notice Calculate total maintenence margin requirement for a wallet by summing each open position's maintanence
   * margin requirement as computed by on-chain feed price
   *
   * @param wallet The wallet address to calculate total maintanence margin requirement for
   */
  function loadTotalMaintenanceMarginRequirementFromOnChainPriceFeed(address wallet) external view returns (uint64) {
    return
      Margin.loadTotalMaintenanceMarginRequirementFromOnChainPriceFeed_delegatecall(
        wallet,
        _balanceTracking,
        _baseAssetSymbolsWithOpenPositionsByWallet,
        _marketOverridesByBaseAssetSymbolAndWallet,
        _marketsByBaseAssetSymbol
      );
  }

  // Wallet exits //

  /**
   * @notice Flags the sending wallet as exited, immediately disabling deposits upon mining. After the Chain Propagation
   * Period passes trades and withdrawals are also disabled for the wallet, and quote asset may then be withdrawn via
   * `withdrawExit`
   */
  function exitWallet() external {
    uint256 blockThreshold = Withdrawing.exitWallet_delegatecall(
      chainPropagationPeriodInBlocks,
      exitFundWallet,
      insuranceFundWallet,
      msg.sender,
      _walletExits
    );

    emit WalletExited(msg.sender, blockThreshold);
  }

  /**
   * @notice Close all open positions and withdraw the net quote balance for an exited wallet. The Chain Propagation
   * Period must have already passed since calling `exitWallet`
   */
  function withdrawExit(address wallet) external {
    (uint256 exitFundPositionOpenedAtBlockNumber, uint64 quantity) = Withdrawing.withdrawExit_delegatecall(
      Withdrawing.WithdrawExitArguments(wallet, custodian, exitFundWallet, quoteAssetAddress),
      _exitFundPositionOpenedAtBlockNumber,
      _balanceTracking,
      _baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      _marketOverridesByBaseAssetSymbolAndWallet,
      _marketsByBaseAssetSymbol,
      _walletExits
    );
    _exitFundPositionOpenedAtBlockNumber = exitFundPositionOpenedAtBlockNumber;

    emit WalletExitWithdrawn(wallet, quantity);
  }

  /**
   * @notice Clears exited status of sending wallet. Upon mining immediately enables deposits, trades, and withdrawals
   * by sending wallet
   */
  function clearWalletExit() external {
    require(Exiting.isWalletExitFinalized(msg.sender, _walletExits), "Wallet exit not finalized");

    delete _walletExits[msg.sender];

    emit WalletExitCleared(msg.sender);
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
    (uint64 timestampInMs, uint256 effectiveBlockNumber) = nonceInvalidationsByWallet.invalidateOrderNonce(
      nonce,
      chainPropagationPeriodInBlocks
    );

    emit OrderNonceInvalidated(msg.sender, nonce, timestampInMs, effectiveBlockNumber);
  }
}
