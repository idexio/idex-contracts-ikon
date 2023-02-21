// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { Constants } from "./libraries/Constants.sol";
import { Owned } from "./Owned.sol";
import { Validations } from "./libraries/Validations.sol";
import { ICustodian, IExchange } from "./libraries/Interfaces.sol";
import { CrossChainBridgeAdapter, OverridableMarketFields } from "./libraries/Structs.sol";

contract Governance is Owned {
  /**
   * @notice Emitted when admin initiates Cross-chain Bridge Adapter upgrade with
   * `initiateCrossChainBridgeAdaptersUpgrade`
   */
  event CrossChainBridgeAdaptersUpgradeInitiated(
    CrossChainBridgeAdapter[] newCrossChainBridgeAdapters,
    uint256 blockThreshold
  );
  /**
   * @notice Emitted when admin cancels previously started Cross-chain Bridge Adapter upgrade with
   * `cancelCrossChainBridgeAdaptersUpgrade`
   */
  event CrossChainBridgeAdaptersUpgradeCanceled();
  /**
   * @notice Emitted when admin finalizes Cross-chain Bridge Adapter upgrade with
   * `finalizeCrossChainBridgeAdaptersUpgrade`
   */
  event CrossChainBridgeAdaptersUpgradeFinalized(CrossChainBridgeAdapter[] newCrossChainBridgeAdapters);
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
   * @notice Emitted when admin initiates IPCS wallet upgrade with `initiateIndexPriceCollectionServiceWalletsUpgrade`
   */
  event IndexPriceCollectionServiceWalletsUpgradeInitiated(
    address[] newIndexPriceCollectionServiceWallets,
    uint256 blockThreshold
  );
  /**
   * @notice Emitted when admin cancels previously started IPCS wallet upgrade with
   * `cancelIndexPriceCollectionServiceWalletsUpgrade`
   */
  event IndexPriceCollectionServiceWalletsUpgradeCanceled();
  /**
   * @notice Emitted when admin finalizes IF wallet upgrade with `finalizeIndexPriceCollectionServiceWalletsUpgrade`
   */
  event IndexPriceCollectionServiceWalletsUpgradeFinalized(address[] newIndexPriceCollectionServiceWallets);
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
  event MarketOverridesUpgradeInitiated(string baseAssetSymbol, address wallet, uint256 blockThreshold);
  /**
   * @notice Emitted when admin cancels previously started market override upgrade with `cancelMarketOverridesUpgrade`
   */
  event MarketOverridesUpgradeCanceled();
  /**
   * @notice Emitted when admin finalizes market override upgrade with `finalizeMarketOverridesUpgrade`
   */
  event MarketOverridesUpgradeFinalized(string baseAssetSymbol, address wallet);

  // Internally used structs //

  struct ContractUpgrade {
    bool exists;
    address newContract;
    uint256 blockThreshold;
  }

  struct CrossChainBridgeAdaptersUpgrade {
    bool exists;
    CrossChainBridgeAdapter[] newCrossChainBridgeAdapters;
    uint256 blockThreshold;
  }

  struct IndexPriceCollectionServiceWalletsUpgrade {
    bool exists;
    address[] newIndexPriceCollectionServiceWallets;
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

  // Storage //

  uint256 public immutable blockDelay;
  ICustodian public custodian;
  IExchange public exchange;
  CrossChainBridgeAdaptersUpgrade public currentCrossChainBridgeAdaptersUpgrade;
  ContractUpgrade public currentExchangeUpgrade;
  ContractUpgrade public currentGovernanceUpgrade;
  IndexPriceCollectionServiceWalletsUpgrade public currentIndexPriceCollectionServiceWalletsUpgrade;
  InsuranceFundWalletUpgrade public currentInsuranceFundWalletUpgrade;
  mapping(string => mapping(address => MarketOverridesUpgrade))
    public currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet;

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
   * @notice Sets the address of the `Custodian` contract. The `Custodian` accepts `Exchange` and
   * `Governance` addresses in its constructor, after which they can only be changed by the
   * `Governance` contract it Therefore the `Custodian` must be deployed last and its address
   * set here on an existing `Governance` contract. This value is immutable once set and cannot be
   * changed again
   *
   * @param newCustodian The address of the `Custodian` contract deployed against this `Governance`
   * contract's address
   */
  function setCustodian(ICustodian newCustodian) external onlyAdmin {
    require(custodian == ICustodian(payable(address(0x0))), "Custodian can only be set once");
    require(Address.isContract(address(newCustodian)), "Invalid address");

    custodian = newCustodian;
  }

  // Exchange upgrade //

  /**
   * @notice Initiates `Exchange` contract upgrade proccess on `Custodian`. Once `blockDelay` has passed
   * the process can be finalized with `finalizeExchangeUpgrade`
   *
   * @param newExchange The address of the new `Exchange` contract
   */
  function initiateExchangeUpgrade(address newExchange) external onlyAdmin {
    require(Address.isContract(address(newExchange)), "Invalid address");
    require(newExchange != custodian.exchange(), "Must be different from current Exchange");
    require(!currentExchangeUpgrade.exists, "Exchange upgrade already in progress");

    currentExchangeUpgrade = ContractUpgrade(true, newExchange, block.number + blockDelay);

    emit ExchangeUpgradeInitiated(custodian.exchange(), newExchange, currentExchangeUpgrade.blockThreshold);
  }

  /**
   * @notice Cancels an in-flight `Exchange` contract upgrade that has not yet been finalized
   */
  function cancelExchangeUpgrade() external onlyAdmin {
    require(currentExchangeUpgrade.exists, "No Exchange upgrade in progress");

    address newExchange = currentExchangeUpgrade.newContract;
    delete currentExchangeUpgrade;

    emit ExchangeUpgradeCanceled(custodian.exchange(), newExchange);
  }

  /**
   * @notice Finalizes the `Exchange` contract upgrade by changing the contract address on the `Custodian`
   * contract with `setExchange`. The number of blocks specified by `blockDelay` must have passed since calling
   * `initiateExchangeUpgrade`
   *
   * @param newExchange The address of the new `Exchange` contract. Must equal the address provided to
   * `initiateExchangeUpgrade`
   */
  function finalizeExchangeUpgrade(address newExchange) external onlyAdmin {
    require(currentExchangeUpgrade.exists, "No Exchange upgrade in progress");
    require(currentExchangeUpgrade.newContract == newExchange, "Address mismatch");
    require(block.number >= currentExchangeUpgrade.blockThreshold, "Block threshold not yet reached");

    address oldExchange = custodian.exchange();
    custodian.setExchange(newExchange);
    delete currentExchangeUpgrade;

    emit ExchangeUpgradeFinalized(oldExchange, newExchange);
  }

  // Governance upgrade //

  /**
   * @notice Initiates `Governance` contract upgrade proccess on `Custodian`. Once `blockDelay` has passed
   * the process can be finalized with `finalizeGovernanceUpgrade`
   *
   * @param newGovernance The address of the new `Governance` contract
   */
  function initiateGovernanceUpgrade(address newGovernance) external onlyAdmin {
    require(Address.isContract(address(newGovernance)), "Invalid address");
    require(newGovernance != custodian.governance(), "Must be different from current Governance");
    require(!currentGovernanceUpgrade.exists, "Governance upgrade already in progress");

    currentGovernanceUpgrade = ContractUpgrade(true, newGovernance, block.number + blockDelay);

    emit GovernanceUpgradeInitiated(custodian.governance(), newGovernance, currentGovernanceUpgrade.blockThreshold);
  }

  /**
   * @notice Cancels an in-flight `Governance` contract upgrade that has not yet been finalized
   */
  function cancelGovernanceUpgrade() external onlyAdmin {
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
  function finalizeGovernanceUpgrade(address newGovernance) external onlyAdmin {
    require(currentGovernanceUpgrade.exists, "No Governance upgrade in progress");
    require(currentGovernanceUpgrade.newContract == newGovernance, "Address mismatch");
    require(block.number >= currentGovernanceUpgrade.blockThreshold, "Block threshold not yet reached");

    address oldGovernance = custodian.governance();
    custodian.setGovernance(newGovernance);
    delete currentGovernanceUpgrade;

    emit GovernanceUpgradeFinalized(oldGovernance, newGovernance);
  }

  // Field upgrade governance //

  // solhint-disable-next-line func-name-mixedcase
  function initiateCrossChainBridgeAdaptersUpgrade_delegatecall(
    CrossChainBridgeAdapter[] memory newCrossChainBridgeAdapters
  ) public {
    require(!currentCrossChainBridgeAdaptersUpgrade.exists, "IPCS wallet upgrade already in progress");

    for (uint8 i = 0; i < newCrossChainBridgeAdapters.length; i++) {
      // Local adapters (no cross-chain bridges should have a zero address for the adapter contract)
      require(
        newCrossChainBridgeAdapters[i].adapterContract != address(0x0) || newCrossChainBridgeAdapters[0].isLocal,
        "Invalid adapter address"
      );
      currentCrossChainBridgeAdaptersUpgrade.newCrossChainBridgeAdapters.push(newCrossChainBridgeAdapters[i]);
    }

    currentCrossChainBridgeAdaptersUpgrade.exists = true;
    currentCrossChainBridgeAdaptersUpgrade.blockThreshold = block.number + Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS;

    emit CrossChainBridgeAdaptersUpgradeInitiated(
      newCrossChainBridgeAdapters,
      currentCrossChainBridgeAdaptersUpgrade.blockThreshold
    );
  }

  // solhint-disable-next-line func-name-mixedcase
  function cancelCrossChainBridgeAdaptersUpgrade_delegatecall()
    public
    returns (CrossChainBridgeAdapter[] memory newCrossChainBridgeAdaptersUpgrade)
  {
    require(currentIndexPriceCollectionServiceWalletsUpgrade.exists, "No adapter upgrade in progress");

    newCrossChainBridgeAdaptersUpgrade = currentCrossChainBridgeAdaptersUpgrade.newCrossChainBridgeAdapters;

    delete currentCrossChainBridgeAdaptersUpgrade;

    emit CrossChainBridgeAdaptersUpgradeCanceled();
  }

  // solhint-disable-next-line func-name-mixedcase
  function finalizeCrossChainBridgeAdaptersUpgrade_delegatecall(
    CrossChainBridgeAdapter[] memory newCrossChainBridgeAdapters
  ) public {
    require(currentCrossChainBridgeAdaptersUpgrade.exists, "No adapter upgrade in progress");

    require(block.number >= currentCrossChainBridgeAdaptersUpgrade.blockThreshold, "Block threshold not yet reached");

    for (uint8 i = 0; i < newCrossChainBridgeAdapters.length; i++) {
      require(
        currentCrossChainBridgeAdaptersUpgrade.newCrossChainBridgeAdapters[i].adapterContract ==
          newCrossChainBridgeAdapters[i].adapterContract,
        "Address mismatch"
      );
    }

    IExchange(custodian.exchange()).setCrossChainBridgeAdapters(newCrossChainBridgeAdapters);

    delete currentCrossChainBridgeAdaptersUpgrade;

    emit CrossChainBridgeAdaptersUpgradeFinalized(newCrossChainBridgeAdapters);
  }

  // solhint-disable-next-line func-name-mixedcase
  function initiateIndexPriceCollectionServiceWalletsUpgrade_delegatecall(
    address[] memory newIndexPriceCollectionServiceWallets
  ) public {
    for (uint8 i = 0; i < newIndexPriceCollectionServiceWallets.length; i++) {
      require(newIndexPriceCollectionServiceWallets[i] != address(0x0), "Invalid IF wallet address");
    }

    require(!currentIndexPriceCollectionServiceWalletsUpgrade.exists, "IPCS wallet upgrade already in progress");

    currentIndexPriceCollectionServiceWalletsUpgrade = IndexPriceCollectionServiceWalletsUpgrade(
      true,
      newIndexPriceCollectionServiceWallets,
      block.number + Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS
    );

    emit IndexPriceCollectionServiceWalletsUpgradeInitiated(
      newIndexPriceCollectionServiceWallets,
      currentIndexPriceCollectionServiceWalletsUpgrade.blockThreshold
    );
  }

  // solhint-disable-next-line func-name-mixedcase
  function cancelIndexPriceCollectionServiceWalletsUpgrade_delegatecall()
    public
    returns (address[] memory newIndexPriceCollectionServiceWallets)
  {
    require(currentIndexPriceCollectionServiceWalletsUpgrade.exists, "No IPCS wallet upgrade in progress");

    newIndexPriceCollectionServiceWallets = currentIndexPriceCollectionServiceWalletsUpgrade
      .newIndexPriceCollectionServiceWallets;

    delete currentIndexPriceCollectionServiceWalletsUpgrade;

    emit IndexPriceCollectionServiceWalletsUpgradeCanceled();
  }

  // solhint-disable-next-line func-name-mixedcase
  function finalizeIndexPriceCollectionServiceWalletsUpgrade_delegatecall(
    address[] memory newIndexPriceCollectionServiceWallets
  ) public {
    require(currentIndexPriceCollectionServiceWalletsUpgrade.exists, "No IPCS wallet upgrade in progress");

    for (uint8 i = 0; i < newIndexPriceCollectionServiceWallets.length; i++) {
      require(
        currentIndexPriceCollectionServiceWalletsUpgrade.newIndexPriceCollectionServiceWallets[i] ==
          newIndexPriceCollectionServiceWallets[i],
        "Address mismatch"
      );
    }

    require(
      block.number >= currentIndexPriceCollectionServiceWalletsUpgrade.blockThreshold,
      "Block threshold not yet reached"
    );

    IExchange(custodian.exchange()).setIndexPriceCollectionServiceWallets(newIndexPriceCollectionServiceWallets);

    delete (currentIndexPriceCollectionServiceWalletsUpgrade);

    emit IndexPriceCollectionServiceWalletsUpgradeFinalized(newIndexPriceCollectionServiceWallets);
  }

  // solhint-disable-next-line func-name-mixedcase
  function initiateInsuranceFundWalletUpgrade_delegatecall(address newInsuranceFundWallet) public {
    require(newInsuranceFundWallet != address(0x0), "Invalid IF wallet address");
    require(!currentInsuranceFundWalletUpgrade.exists, "IF wallet upgrade already in progress");

    currentInsuranceFundWalletUpgrade = InsuranceFundWalletUpgrade(
      true,
      newInsuranceFundWallet,
      block.number + Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS
    );

    emit InsuranceFundWalletUpgradeInitiated(newInsuranceFundWallet, currentInsuranceFundWalletUpgrade.blockThreshold);
  }

  // solhint-disable-next-line func-name-mixedcase
  function cancelInsuranceFundWalletUpgrade_delegatecall() public returns (address newInsuranceFundWallet) {
    require(currentInsuranceFundWalletUpgrade.exists, "No IF wallet upgrade in progress");

    newInsuranceFundWallet = currentInsuranceFundWalletUpgrade.newInsuranceFundWallet;

    delete currentInsuranceFundWalletUpgrade;

    emit InsuranceFundWalletUpgradeCanceled();
  }

  // solhint-disable-next-line func-name-mixedcase
  function finalizeInsuranceFundWalletUpgrade_delegatecall(address newInsuranceFundWallet) public {
    require(currentInsuranceFundWalletUpgrade.exists, "No IF wallet upgrade in progress");
    require(currentInsuranceFundWalletUpgrade.newInsuranceFundWallet == newInsuranceFundWallet, "Address mismatch");
    require(block.number >= currentInsuranceFundWalletUpgrade.blockThreshold, "Block threshold not yet reached");

    IExchange(custodian.exchange()).setInsuranceFundWallet(newInsuranceFundWallet);

    delete (currentInsuranceFundWalletUpgrade);

    emit InsuranceFundWalletUpgradeFinalized(newInsuranceFundWallet);
  }

  function initiateMarketOverridesUpgrade(
    string memory baseAssetSymbol,
    OverridableMarketFields memory overridableFields,
    address wallet
  ) internal returns (uint256 blockThreshold) {
    require(
      !currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet[baseAssetSymbol][wallet].exists,
      "Market override upgrade already in progress for wallet"
    );

    Validations.validateOverridableMarketFields(overridableFields);

    blockThreshold = block.number + Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS;
    currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet[baseAssetSymbol][wallet] = MarketOverridesUpgrade(
      true,
      overridableFields,
      blockThreshold
    );

    emit MarketOverridesUpgradeInitiated(baseAssetSymbol, wallet, blockThreshold);
  }

  function cancelMarketOverridesUpgrade(string memory baseAssetSymbol, address wallet) internal {
    require(
      currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet[baseAssetSymbol][wallet].exists,
      "No market override upgrade in progress for wallet"
    );

    delete currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet[baseAssetSymbol][wallet];

    emit MarketOverridesUpgradeCanceled();
  }

  function finalizeMarketOverridesUpgrade(
    string memory baseAssetSymbol,
    address wallet
  ) internal returns (OverridableMarketFields memory marketOverrides) {
    MarketOverridesUpgrade storage upgrade = currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet[baseAssetSymbol][
      wallet
    ];
    require(upgrade.exists, "No market override upgrade in progress for wallet");
    require(block.number >= upgrade.blockThreshold, "Block threshold not yet reached");

    marketOverrides = upgrade.newMarketOverrides;

    IExchange(custodian.exchange()).setMarketOverrides(baseAssetSymbol, marketOverrides, wallet);

    delete (currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet[baseAssetSymbol][wallet]);

    emit MarketOverridesUpgradeFinalized(baseAssetSymbol, wallet);
  }
}
