// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { Constants } from "./libraries/Constants.sol";
import { Owned } from "./Owned.sol";
import { String } from "./libraries/String.sol";
import { Validations } from "./libraries/Validations.sol";
import { OverridableMarketFields } from "./libraries/Structs.sol";
import { IBridgeAdapter, ICustodian, IExchange, IIndexPriceAdapter, IOraclePriceAdapter } from "./libraries/Interfaces.sol";

contract Governance is Owned {
  // State variables //

  uint256 public immutable blockDelay;
  ICustodian public custodian;

  // State variables - upgrade tracking //

  BridgeAdaptersUpgrade public currentBridgeAdaptersUpgrade;
  ContractUpgrade public currentExchangeUpgrade;
  ContractUpgrade public currentGovernanceUpgrade;
  IndexPriceAdaptersUpgrade public currentIndexPriceAdaptersUpgrade;
  InsuranceFundWalletUpgrade public currentInsuranceFundWalletUpgrade;
  mapping(string => mapping(address => MarketOverridesUpgrade))
    public currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet;
  ContractUpgrade public currentOraclePriceAdapterUpgrade;

  // Internally used structs //

  struct ContractUpgrade {
    bool exists;
    address newContract;
    uint256 blockThreshold;
  }

  struct BridgeAdaptersUpgrade {
    bool exists;
    IBridgeAdapter[] newBridgeAdapters;
    uint256 blockThreshold;
  }

  struct IndexPriceAdaptersUpgrade {
    bool exists;
    IIndexPriceAdapter[] newIndexPriceAdapters;
    uint256 blockThreshold;
  }

  struct InsuranceFundWalletUpgrade {
    bool exists;
    address newInsuranceFundWallet;
    uint256 blockThreshold;
  }

  struct MarketOverridesUpgrade {
    bool exists;
    OverridableMarketFields newMarketOverrides;
    uint256 blockThreshold;
  }

  /**
   * @notice Emitted when admin initiates Bridge Adapter upgrade with
   * `initiateBridgeAdaptersUpgrade`
   */
  event BridgeAdaptersUpgradeInitiated(IBridgeAdapter[] newBridgeAdapters, uint256 blockThreshold);
  /**
   * @notice Emitted when admin cancels previously started Bridge Adapter upgrade with
   * `cancelBridgeAdaptersUpgrade`
   */
  event BridgeAdaptersUpgradeCanceled();
  /**
   * @notice Emitted when admin finalizes Bridge Adapter upgrade with
   * `finalizeBridgeAdaptersUpgrade`
   */
  event BridgeAdaptersUpgradeFinalized(IBridgeAdapter[] newBridgeAdapters);
  /**
   * @notice Emitted when admin initiates upgrade of `Exchange` contract address on `Custodian` via
   * `initiateExchangeUpgrade`
   */
  event ExchangeUpgradeInitiated(address oldExchange, address newExchange, uint256 blockThreshold);
  /**
   * @notice Emitted when admin cancels previously started `Exchange` upgrade with `cancelExchangeUpgrade`
   */
  event ExchangeUpgradeCanceled(address oldExchange, address newExchange);
  /**
   * @notice Emitted when admin finalizes `Exchange` upgrade via `finalizeExchangeUpgrade`
   */
  event ExchangeUpgradeFinalized(address oldExchange, address newExchange);
  /**
   * @notice Emitted when admin initiates upgrade of `Governance` contract address on `Custodian` via
   * `initiateGovernanceUpgrade`
   */
  event GovernanceUpgradeInitiated(address oldGovernance, address newGovernance, uint256 blockThreshold);
  /**
   * @notice Emitted when admin cancels previously started `Governance` upgrade with `cancelGovernanceUpgrade`
   */
  event GovernanceUpgradeCanceled(address oldGovernance, address newGovernance);
  /**
   * @notice Emitted when admin finalizes `Governance` upgrade via `finalizeGovernanceUpgrade`, effectively replacing
   * this contract and rendering it non-functioning
   */
  event GovernanceUpgradeFinalized(address oldGovernance, address newGovernance);
  /**
   * @notice Emitted when admin initiates Index Price Adapter  upgrade with `initiateIndexPriceAdaptersUpgrade`
   */
  event IndexPriceAdaptersUpgradeInitiated(IIndexPriceAdapter[] newIndexPriceAdapters, uint256 blockThreshold);
  /**
   * @notice Emitted when admin cancels previously started Index Price Adapter upgrade with
   * `cancelIndexPriceAdaptersUpgrade`
   */
  event IndexPriceAdaptersUpgradeCanceled();
  /**
   * @notice Emitted when admin finalizes IF wallet upgrade with `finalizeIndexPriceAdaptersUpgrade`
   */
  event IndexPriceAdaptersUpgradeFinalized(IIndexPriceAdapter[] newIndexPriceAdapters);
  /**
   * @notice Emitted when admin initiates IF wallet upgrade with `initiateInsuranceFundWalletUpgrade`
   */
  event InsuranceFundWalletUpgradeInitiated(address newInsuranceFundWallet, uint256 blockThreshold);
  /**
   * @notice Emitted when admin cancels previously started IF wallet upgrade with `cancelInsuranceFundWalletUpgrade`
   */
  event InsuranceFundWalletUpgradeCanceled();
  /**
   * @notice Emitted when admin finalizes IF wallet upgrade with `finalizeInsuranceFundWalletUpgrade`
   */
  event InsuranceFundWalletUpgradeFinalized(address newInsuranceFundWallet);
  /**
   * @notice Emitted when admin initiates market override upgrade with `initiateMarketOverridesUpgrade`
   */
  event MarketOverridesUpgradeInitiated(
    string baseAssetSymbol,
    address wallet,
    OverridableMarketFields overridableFields,
    uint256 blockThreshold
  );
  /**
   * @notice Emitted when admin cancels previously started market override upgrade with `cancelMarketOverridesUpgrade`
   */
  event MarketOverridesUpgradeCanceled();
  /**
   * @notice Emitted when admin finalizes market override upgrade with `finalizeMarketOverridesUpgrade`
   */
  event MarketOverridesUpgradeFinalized(
    string baseAssetSymbol,
    address wallet,
    OverridableMarketFields overridableFields
  );
  /**
   * @notice Emitted when admin initiates Oracle Price Adapter upgrade with `initiateOraclePriceAdapterUpgrade`
   */
  event OraclePriceAdapterUpgradeInitiated(IOraclePriceAdapter newOraclePriceAdapter, uint256 blockThreshold);
  /**
   * @notice Emitted when admin cancels previously started Oracle Price Adapter upgrade with `cancelOraclePriceAdapterUpgrade`
   */
  event OraclePriceAdapterUpgradeCanceled();
  /**
   * @notice Emitted when admin finalizes Oracle Price Adapter upgrade with `finalizeOraclePriceAdapterUpgrade`
   */
  event OraclePriceAdapterUpgradeFinalized(IOraclePriceAdapter newOraclePriceAdapter);

  modifier onlyAdminOrDispatcher() {
    require(
      msg.sender == adminWallet || msg.sender == _loadExchange().dispatcherWallet(),
      "Caller must be Admin or Dispatcher wallet"
    );
    _;
  }

  /**
   * @notice Instantiate a new `Governance` contract
   *
   * @dev Sets `owner` and `admin` to `msg.sender`. Sets the values for `blockDelay` governing `Exchange`
   * and `Governance` upgrades. This value is immutable, and cannot be changed after construction
   *
   * @param blockDelay_ The minimum number of blocks that must be mined after initiating an `Exchange`
   * or `Governance` upgrade before the upgrade may be finalized
   */
  constructor(uint256 blockDelay_) Owned() {
    blockDelay = blockDelay_;
  }

  /**
   * @notice Sets the address of the `Custodian` contract. The `Custodian` accepts `Exchange` and `Governance` addresses
   * in its constructor, after which they can only be changed by the `Governance` contract itself. Therefore the
   * `Custodian` must be deployed last and its address set here on an existing `Governance` contract. This value is
   * immutable once set and cannot be changed again
   *
   * @param newCustodian The address of the `Custodian` contract deployed against this `Governance`
   * contract's address
   */
  function setCustodian(ICustodian newCustodian) public onlyAdmin {
    require(custodian == ICustodian(payable(address(0x0))), "Custodian can only be set once");
    require(Address.isContract(address(newCustodian)), "Invalid address");

    custodian = newCustodian;
  }

  // Exchange upgrade //

  /**
   * @notice Initiates `Exchange` contract upgrade process on `Custodian`. Once `blockDelay` has passed
   * the process can be finalized with `finalizeExchangeUpgrade`
   *
   * @param newExchange The address of the new `Exchange` contract
   */
  function initiateExchangeUpgrade(address newExchange) public onlyAdmin {
    require(Address.isContract(address(newExchange)), "Invalid address");
    require(newExchange != address(_loadExchange()), "Must be different from current Exchange");
    require(!currentExchangeUpgrade.exists, "Exchange upgrade already in progress");

    currentExchangeUpgrade = ContractUpgrade(true, newExchange, block.number + blockDelay);

    emit ExchangeUpgradeInitiated(address(_loadExchange()), newExchange, currentExchangeUpgrade.blockThreshold);
  }

  /**
   * @notice Cancels an in-flight `Exchange` contract upgrade that has not yet been finalized
   */
  function cancelExchangeUpgrade() public onlyAdmin {
    require(currentExchangeUpgrade.exists, "No Exchange upgrade in progress");

    address newExchange = currentExchangeUpgrade.newContract;
    delete currentExchangeUpgrade;

    emit ExchangeUpgradeCanceled(address(_loadExchange()), newExchange);
  }

  /**
   * @notice Finalizes the `Exchange` contract upgrade by changing the contract address on the `Custodian`
   * contract with `setExchange`. The number of blocks specified by `blockDelay` must have passed since calling
   * `initiateExchangeUpgrade`
   *
   * @param newExchange The address of the new `Exchange` contract. Must equal the address provided to
   * `initiateExchangeUpgrade`
   */
  function finalizeExchangeUpgrade(address newExchange) public onlyAdmin {
    require(currentExchangeUpgrade.exists, "No Exchange upgrade in progress");
    require(currentExchangeUpgrade.newContract == newExchange, "Address mismatch");
    require(block.number >= currentExchangeUpgrade.blockThreshold, "Block threshold not yet reached");

    address oldExchange = address(_loadExchange());
    custodian.setExchange(newExchange);
    delete currentExchangeUpgrade;

    emit ExchangeUpgradeFinalized(oldExchange, newExchange);
  }

  // Governance upgrade //

  /**
   * @notice Initiates `Governance` contract upgrade process on `Custodian`. Once `blockDelay` has passed
   * the process can be finalized with `finalizeGovernanceUpgrade`
   *
   * @param newGovernance The address of the new `Governance` contract
   */
  function initiateGovernanceUpgrade(address newGovernance) public onlyAdmin {
    require(Address.isContract(address(newGovernance)), "Invalid address");
    require(newGovernance != custodian.governance(), "Must be different from current Governance");
    require(!currentGovernanceUpgrade.exists, "Governance upgrade already in progress");

    currentGovernanceUpgrade = ContractUpgrade(true, newGovernance, block.number + blockDelay);

    emit GovernanceUpgradeInitiated(custodian.governance(), newGovernance, currentGovernanceUpgrade.blockThreshold);
  }

  /**
   * @notice Cancels an in-flight `Governance` contract upgrade that has not yet been finalized
   */
  function cancelGovernanceUpgrade() public onlyAdmin {
    require(currentGovernanceUpgrade.exists, "No Governance upgrade in progress");

    address newGovernance = currentGovernanceUpgrade.newContract;
    delete currentGovernanceUpgrade;

    emit GovernanceUpgradeCanceled(custodian.governance(), newGovernance);
  }

  /**
   * @notice Finalizes the `Governance` contract upgrade by changing the contract address on the `Custodian`
   * contract with `setGovernance`. The number of blocks specified by `blockDelay` must have passed since calling
   * `initiateGovernanceUpgrade`.
   *
   * @dev After successfully calling this function, this contract will become useless since it is no
   * longer whitelisted in the `Custodian`
   *
   * @param newGovernance The address of the new `Governance` contract. Must equal the address provided to
   * `initiateGovernanceUpgrade`
   */
  function finalizeGovernanceUpgrade(address newGovernance) public onlyAdmin {
    require(currentGovernanceUpgrade.exists, "No Governance upgrade in progress");
    require(currentGovernanceUpgrade.newContract == newGovernance, "Address mismatch");
    require(block.number >= currentGovernanceUpgrade.blockThreshold, "Block threshold not yet reached");

    address oldGovernance = custodian.governance();
    custodian.setGovernance(newGovernance);
    delete currentGovernanceUpgrade;

    emit GovernanceUpgradeFinalized(oldGovernance, newGovernance);
  }

  // Field upgrade governance //

  /**
   * @notice Initiates Bridge Adapter upgrade process. Once block delay has passed the process can be
   * finalized with `finalizeBridgeAdaptersUpgrade`
   *
   * @param newBridgeAdapters The new adapter contract addresses
   */
  function initiateBridgeAdaptersUpgrade(IBridgeAdapter[] memory newBridgeAdapters) public onlyAdmin {
    require(!currentBridgeAdaptersUpgrade.exists, "Bridge adapter upgrade already in progress");

    for (uint8 i = 0; i < newBridgeAdapters.length; i++) {
      require(Address.isContract(address(newBridgeAdapters[i])), "Invalid adapter address");
    }

    currentBridgeAdaptersUpgrade.exists = true;
    currentBridgeAdaptersUpgrade.newBridgeAdapters = newBridgeAdapters;
    currentBridgeAdaptersUpgrade.blockThreshold = block.number + Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS;

    emit BridgeAdaptersUpgradeInitiated(newBridgeAdapters, currentBridgeAdaptersUpgrade.blockThreshold);
  }

  /**
   * @notice Cancels an in-flight Bridge Adapter upgrade that has not yet been finalized
   */
  function cancelBridgeAdaptersUpgrade() public onlyAdmin {
    require(currentBridgeAdaptersUpgrade.exists, "No adapter upgrade in progress");

    delete currentBridgeAdaptersUpgrade;

    emit BridgeAdaptersUpgradeCanceled();
  }

  /**
   * @notice Finalizes the Bridge Adapter upgrade. The number of blocks specified by
   * `Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS` must have passed since calling `initiateBridgeAdaptersUpgrade`
   *
   * @param newBridgeAdapters The new Bridge Adapter contract addresses. Must match the order and values of the
   * addresses provided to `initiateBridgeAdaptersUpgrade`
   */
  function finalizeBridgeAdaptersUpgrade(IBridgeAdapter[] memory newBridgeAdapters) public onlyAdminOrDispatcher {
    require(currentBridgeAdaptersUpgrade.exists, "No adapter upgrade in progress");

    require(block.number >= currentBridgeAdaptersUpgrade.blockThreshold, "Block threshold not yet reached");

    // Verify provided addresses match originals
    require(currentBridgeAdaptersUpgrade.newBridgeAdapters.length == newBridgeAdapters.length, "Address mismatch");
    for (uint8 i = 0; i < newBridgeAdapters.length; i++) {
      require(currentBridgeAdaptersUpgrade.newBridgeAdapters[i] == newBridgeAdapters[i], "Address mismatch");
    }

    _loadExchange().setBridgeAdapters(currentBridgeAdaptersUpgrade.newBridgeAdapters);

    delete currentBridgeAdaptersUpgrade;

    emit BridgeAdaptersUpgradeFinalized(newBridgeAdapters);
  }

  /**
   * @notice Initiates Index Price Adapter upgrade process. Once block delay has passed the process can be finalized
   * with `finalizeIndexPriceAdaptersUpgrade`
   *
   * @param newIndexPriceAdapters The Index Price Adapter contract addresses
   */
  function initiateIndexPriceAdaptersUpgrade(IIndexPriceAdapter[] memory newIndexPriceAdapters) public onlyAdmin {
    for (uint8 i = 0; i < newIndexPriceAdapters.length; i++) {
      require(Address.isContract(address(newIndexPriceAdapters[i])), "Invalid Index Price Adapter address");
    }

    require(!currentIndexPriceAdaptersUpgrade.exists, "Index Price Adapter upgrade already in progress");

    currentIndexPriceAdaptersUpgrade = IndexPriceAdaptersUpgrade(
      true,
      newIndexPriceAdapters,
      block.number + Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS
    );

    emit IndexPriceAdaptersUpgradeInitiated(newIndexPriceAdapters, currentIndexPriceAdaptersUpgrade.blockThreshold);
  }

  /**
   * @notice Cancels an in-flight Index Price Adapter upgrade that has not yet been finalized
   */
  function cancelIndexPriceAdaptersUpgrade() public onlyAdmin {
    require(currentIndexPriceAdaptersUpgrade.exists, "No Index Price Adapter upgrade in progress");

    delete currentIndexPriceAdaptersUpgrade;

    emit IndexPriceAdaptersUpgradeCanceled();
  }

  /**
   * @notice Finalizes the Index Price Adapter upgrade. The number of blocks specified by
   * `Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS` must have passed since calling `initiateIndexPriceAdaptersUpgrade`
   *
   * @param newIndexPriceAdapters The addresses of the new Index Price Adapter contracts. Must match the order and
   * values of the addresses provided to `initiateIndexPriceAdaptersUpgrade`
   */
  function finalizeIndexPriceAdaptersUpgrade(
    IIndexPriceAdapter[] memory newIndexPriceAdapters
  ) public onlyAdminOrDispatcher {
    require(currentIndexPriceAdaptersUpgrade.exists, "No Index Price Adapter upgrade in progress");

    require(
      currentIndexPriceAdaptersUpgrade.newIndexPriceAdapters.length == newIndexPriceAdapters.length,
      "Address mismatch"
    );
    for (uint8 i = 0; i < newIndexPriceAdapters.length; i++) {
      require(
        currentIndexPriceAdaptersUpgrade.newIndexPriceAdapters[i] == newIndexPriceAdapters[i],
        "Address mismatch"
      );
      newIndexPriceAdapters[i].setActive(_loadExchange());
    }

    require(block.number >= currentIndexPriceAdaptersUpgrade.blockThreshold, "Block threshold not yet reached");

    _loadExchange().setIndexPriceAdapters(newIndexPriceAdapters);

    delete (currentIndexPriceAdaptersUpgrade);

    emit IndexPriceAdaptersUpgradeFinalized(newIndexPriceAdapters);
  }

  /**
   * @notice Initiates Insurance Fund wallet upgrade process. Once block delay has passed
   * the process can be finalized with `finalizeInsuranceFundWalletUpgrade`
   *
   * @param newInsuranceFundWallet The IF wallet address
   */
  function initiateInsuranceFundWalletUpgrade(address newInsuranceFundWallet) public onlyAdmin {
    require(newInsuranceFundWallet != address(0x0), "Invalid IF wallet address");
    require(newInsuranceFundWallet != _loadExchange().insuranceFundWallet(), "Must be different from current");

    require(!currentInsuranceFundWalletUpgrade.exists, "IF wallet upgrade already in progress");

    currentInsuranceFundWalletUpgrade = InsuranceFundWalletUpgrade(
      true,
      newInsuranceFundWallet,
      block.number + Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS
    );

    emit InsuranceFundWalletUpgradeInitiated(newInsuranceFundWallet, currentInsuranceFundWalletUpgrade.blockThreshold);
  }

  /**
   * @notice Cancels an in-flight IF wallet upgrade that has not yet been finalized
   */
  function cancelInsuranceFundWalletUpgrade() public onlyAdmin {
    require(currentInsuranceFundWalletUpgrade.exists, "No IF wallet upgrade in progress");

    delete currentInsuranceFundWalletUpgrade;

    emit InsuranceFundWalletUpgradeCanceled();
  }

  /**
   * @notice Finalizes the IF wallet upgrade. The number of blocks specified by
   * `Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS` must have passed since calling `initiateInsuranceFundWalletUpgrade`
   *
   * @param newInsuranceFundWallet The address of the new IF wallet. Must equal the address provided to
   * `initiateInsuranceFundWalletUpgrade`
   */
  function finalizeInsuranceFundWalletUpgrade(address newInsuranceFundWallet) public onlyAdminOrDispatcher {
    require(currentInsuranceFundWalletUpgrade.exists, "No IF wallet upgrade in progress");
    require(currentInsuranceFundWalletUpgrade.newInsuranceFundWallet == newInsuranceFundWallet, "Address mismatch");
    require(block.number >= currentInsuranceFundWalletUpgrade.blockThreshold, "Block threshold not yet reached");

    require(
      _loadExchange().loadBaseAssetSymbolsWithOpenPositionsByWallet(_loadExchange().insuranceFundWallet()).length == 0,
      "Current IF cannot have open positions"
    );
    require(
      _loadExchange().loadBaseAssetSymbolsWithOpenPositionsByWallet(newInsuranceFundWallet).length == 0,
      "New IF cannot have open positions"
    );

    _loadExchange().setInsuranceFundWallet(newInsuranceFundWallet);
    delete (currentInsuranceFundWalletUpgrade);

    emit InsuranceFundWalletUpgradeFinalized(newInsuranceFundWallet);
  }

  /**
   * @notice Initiates market override upgrade process for `wallet`. If `wallet` is zero address, then the overrides
   * will become the new default values for the market. Once `Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS` has passed the
   * process can be finalized with `finalizeMarketOverridesUpgrade`
   *
   * @param baseAssetSymbol The base asset symbol for the market
   * @param overridableFields New values for overridable fields
   * @param wallet The wallet to apply overrides to. If zero, overrides apply to entire market
   */
  function initiateMarketOverridesUpgrade(
    string memory baseAssetSymbol,
    OverridableMarketFields memory overridableFields,
    address wallet
  ) public onlyAdmin {
    require(
      !currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet[baseAssetSymbol][wallet].exists,
      "Market override upgrade already in progress for wallet"
    );

    Validations.validateOverridableMarketFields(overridableFields);

    uint256 blockThreshold = block.number + Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS;
    currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet[baseAssetSymbol][wallet] = MarketOverridesUpgrade(
      true,
      overridableFields,
      blockThreshold
    );

    emit MarketOverridesUpgradeInitiated(baseAssetSymbol, wallet, overridableFields, blockThreshold);
  }

  /**
   * @notice Cancels an in-flight market override upgrade process that has not yet been finalized
   */
  function cancelMarketOverridesUpgrade(string memory baseAssetSymbol, address wallet) public onlyAdmin {
    require(
      currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet[baseAssetSymbol][wallet].exists,
      "No market override upgrade in progress for wallet"
    );

    delete currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet[baseAssetSymbol][wallet];

    emit MarketOverridesUpgradeCanceled();
  }

  /**
   * @notice Finalizes a market override upgrade process by changing the market's default overridable field values if
   * `wallet` is the zero address, or assigning wallet-specific overrides otherwise. The number of blocks specified by
   * `Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS` must have passed since calling `initiateMarketOverridesUpgrade`
   */
  function finalizeMarketOverridesUpgrade(
    string memory baseAssetSymbol,
    OverridableMarketFields memory overridableFields,
    address wallet
  ) public onlyAdminOrDispatcher {
    MarketOverridesUpgrade memory upgrade = currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet[baseAssetSymbol][
      wallet
    ];
    require(upgrade.exists, "No market override upgrade in progress for wallet");
    require(block.number >= upgrade.blockThreshold, "Block threshold not yet reached");

    require(
      upgrade.newMarketOverrides.initialMarginFraction == overridableFields.initialMarginFraction &&
        upgrade.newMarketOverrides.maintenanceMarginFraction == overridableFields.maintenanceMarginFraction &&
        upgrade.newMarketOverrides.incrementalInitialMarginFraction ==
        overridableFields.incrementalInitialMarginFraction &&
        upgrade.newMarketOverrides.baselinePositionSize == overridableFields.baselinePositionSize &&
        upgrade.newMarketOverrides.incrementalPositionSize == overridableFields.incrementalPositionSize &&
        upgrade.newMarketOverrides.maximumPositionSize == overridableFields.maximumPositionSize &&
        upgrade.newMarketOverrides.minimumPositionSize == overridableFields.minimumPositionSize,
      "Overrides mismatch"
    );

    _loadExchange().setMarketOverrides(baseAssetSymbol, overridableFields, wallet);

    delete (currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet[baseAssetSymbol][wallet]);

    emit MarketOverridesUpgradeFinalized(baseAssetSymbol, wallet, overridableFields);
  }

  /**
   * @notice Initiates Oracle Price Adapter upgrade process. Once block delay has passed the process can be
   * finalized with `finalizeOraclePriceAdapterUpgrade`
   *
   * @param newOraclePriceAdapter The new adapter contract address
   */
  function initiateOraclePriceAdapterUpgrade(IOraclePriceAdapter newOraclePriceAdapter) public onlyAdmin {
    require(!currentOraclePriceAdapterUpgrade.exists, "Oracle price adapter upgrade already in progress");

    require(Address.isContract(address(newOraclePriceAdapter)), "Invalid Oracle Price Adapter address");

    currentOraclePriceAdapterUpgrade.exists = true;
    currentOraclePriceAdapterUpgrade.newContract = address(newOraclePriceAdapter);
    currentOraclePriceAdapterUpgrade.blockThreshold = block.number + Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS;

    emit OraclePriceAdapterUpgradeInitiated(newOraclePriceAdapter, currentBridgeAdaptersUpgrade.blockThreshold);
  }

  /**
   * @notice Cancels an in-flight Oracle Price Adapter upgrade that has not yet been finalized
   */
  function cancelOraclePriceAdapterUpgrade() public onlyAdmin {
    require(currentOraclePriceAdapterUpgrade.exists, "No Oracle Price Adapter upgrade in progress");

    delete currentOraclePriceAdapterUpgrade;

    emit OraclePriceAdapterUpgradeCanceled();
  }

  /**
   * @notice Finalizes the Oracle Price Adapter upgrade. The number of blocks specified by
   * `Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS` must have passed since calling `initiateOraclePriceAdapterUpgrade`
   *
   * @param newOraclePriceAdapter The address of the new Oracle Price Adapter contract. Must equal the address provided
   * to `initiateOraclePriceAdapterUpgrade`
   */
  function finalizeOraclePriceAdapterUpgrade(IOraclePriceAdapter newOraclePriceAdapter) public onlyAdminOrDispatcher {
    require(currentOraclePriceAdapterUpgrade.exists, "No Oracle Price Adapter upgrade in progress");

    require(currentOraclePriceAdapterUpgrade.newContract == address(newOraclePriceAdapter), "Address mismatch");

    require(block.number >= currentOraclePriceAdapterUpgrade.blockThreshold, "Block threshold not yet reached");

    newOraclePriceAdapter.setActive(_loadExchange());
    _loadExchange().setOraclePriceAdapter(newOraclePriceAdapter);

    delete (currentOraclePriceAdapterUpgrade);

    emit OraclePriceAdapterUpgradeFinalized(newOraclePriceAdapter);
  }

  function _loadExchange() private view returns (IExchange) {
    return IExchange(custodian.exchange());
  }
}
