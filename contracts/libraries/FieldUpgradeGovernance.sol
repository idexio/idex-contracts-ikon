// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Constants } from "./Constants.sol";
import { CrossChainBridgeAdapter, OverridableMarketFields } from "./Structs.sol";

library FieldUpgradeGovernance {
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

  struct Storage {
    CrossChainBridgeAdaptersUpgrade currentCrossChainBridgeAdaptersUpgrade;
    IndexPriceCollectionServiceWalletsUpgrade currentIndexPriceCollectionServiceWalletsUpgrade;
    InsuranceFundWalletUpgrade currentInsuranceFundWalletUpgrade;
    mapping(string => mapping(address => MarketOverridesUpgrade)) currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet;
  }

  // solhint-disable-next-line func-name-mixedcase
  function initiateCrossChainBridgeAdaptersUpgrade_delegatecall(
    Storage storage self,
    CrossChainBridgeAdapter[] memory newCrossChainBridgeAdapters
  ) public {
    require(!self.currentCrossChainBridgeAdaptersUpgrade.exists, "IPCS wallet upgrade already in progress");

    for (uint8 i = 0; i < newCrossChainBridgeAdapters.length; i++) {
      // Local adapters (no cross-chain bridges should have a zero address for the adapter contract)
      require(
        newCrossChainBridgeAdapters[i].adapterContract != address(0x0) || newCrossChainBridgeAdapters[0].isLocal,
        "Invalid adapter address"
      );
      self.currentCrossChainBridgeAdaptersUpgrade.newCrossChainBridgeAdapters.push(newCrossChainBridgeAdapters[i]);
    }

    self.currentCrossChainBridgeAdaptersUpgrade.exists = true;
    self.currentCrossChainBridgeAdaptersUpgrade.blockThreshold = block.number + Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS;
  }

  // solhint-disable-next-line func-name-mixedcase
  function cancelCrossChainBridgeAdaptersUpgrade_delegatecall(
    Storage storage self
  ) public returns (CrossChainBridgeAdapter[] memory newCrossChainBridgeAdaptersUpgrade) {
    require(self.currentIndexPriceCollectionServiceWalletsUpgrade.exists, "No adapter upgrade in progress");

    newCrossChainBridgeAdaptersUpgrade = self.currentCrossChainBridgeAdaptersUpgrade.newCrossChainBridgeAdapters;

    delete self.currentCrossChainBridgeAdaptersUpgrade;
  }

  // solhint-disable-next-line func-name-mixedcase
  function finalizeCrossChainBridgeAdaptersUpgrade_delegatecall(
    Storage storage self,
    CrossChainBridgeAdapter[] memory newCrossChainBridgeAdapters,
    CrossChainBridgeAdapter[] storage crossChainBridgeAdapters
  ) public {
    require(self.currentCrossChainBridgeAdaptersUpgrade.exists, "No adapter upgrade in progress");

    require(
      block.number >= self.currentCrossChainBridgeAdaptersUpgrade.blockThreshold,
      "Block threshold not yet reached"
    );

    for (uint8 i = 0; i < newCrossChainBridgeAdapters.length; i++) {
      require(
        self.currentCrossChainBridgeAdaptersUpgrade.newCrossChainBridgeAdapters[i].adapterContract ==
          newCrossChainBridgeAdapters[i].adapterContract,
        "Address mismatch"
      );
      crossChainBridgeAdapters.push(newCrossChainBridgeAdapters[i]);
    }

    delete (self.currentCrossChainBridgeAdaptersUpgrade);
  }

  // solhint-disable-next-line func-name-mixedcase
  function initiateIndexPriceCollectionServiceWalletsUpgrade_delegatecall(
    Storage storage self,
    address[] memory newIndexPriceCollectionServiceWallets
  ) public {
    for (uint8 i = 0; i < newIndexPriceCollectionServiceWallets.length; i++) {
      require(newIndexPriceCollectionServiceWallets[i] != address(0x0), "Invalid IF wallet address");
    }

    require(!self.currentIndexPriceCollectionServiceWalletsUpgrade.exists, "IPCS wallet upgrade already in progress");

    self.currentIndexPriceCollectionServiceWalletsUpgrade = IndexPriceCollectionServiceWalletsUpgrade(
      true,
      newIndexPriceCollectionServiceWallets,
      block.number + Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS
    );
  }

  // solhint-disable-next-line func-name-mixedcase
  function cancelIndexPriceCollectionServiceWalletsUpgrade_delegatecall(
    Storage storage self
  ) public returns (address[] memory newIndexPriceCollectionServiceWallets) {
    require(self.currentIndexPriceCollectionServiceWalletsUpgrade.exists, "No IPCS wallet upgrade in progress");

    newIndexPriceCollectionServiceWallets = self
      .currentIndexPriceCollectionServiceWalletsUpgrade
      .newIndexPriceCollectionServiceWallets;

    delete self.currentIndexPriceCollectionServiceWalletsUpgrade;
  }

  // solhint-disable-next-line func-name-mixedcase
  function finalizeIndexPriceCollectionServiceWalletsUpgrade_delegatecall(
    Storage storage self,
    address[] memory newIndexPriceCollectionServiceWallets
  ) public {
    require(self.currentIndexPriceCollectionServiceWalletsUpgrade.exists, "No IPCS wallet upgrade in progress");

    for (uint8 i = 0; i < newIndexPriceCollectionServiceWallets.length; i++) {
      require(
        self.currentIndexPriceCollectionServiceWalletsUpgrade.newIndexPriceCollectionServiceWallets[i] ==
          newIndexPriceCollectionServiceWallets[i],
        "Address mismatch"
      );
    }

    require(
      block.number >= self.currentIndexPriceCollectionServiceWalletsUpgrade.blockThreshold,
      "Block threshold not yet reached"
    );

    delete (self.currentIndexPriceCollectionServiceWalletsUpgrade);
  }

  // solhint-disable-next-line func-name-mixedcase
  function initiateInsuranceFundWalletUpgrade_delegatecall(
    Storage storage self,
    address currentInsuranceFundWallet,
    address newInsuranceFundWallet
  ) public {
    require(newInsuranceFundWallet != address(0x0), "Invalid IF wallet address");
    require(newInsuranceFundWallet != currentInsuranceFundWallet, "Must be different from current");
    require(!self.currentInsuranceFundWalletUpgrade.exists, "IF wallet upgrade already in progress");

    self.currentInsuranceFundWalletUpgrade = InsuranceFundWalletUpgrade(
      true,
      newInsuranceFundWallet,
      block.number + Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS
    );
  }

  // solhint-disable-next-line func-name-mixedcase
  function cancelInsuranceFundWalletUpgrade_delegatecall(
    Storage storage self
  ) public returns (address newInsuranceFundWallet) {
    require(self.currentInsuranceFundWalletUpgrade.exists, "No IF wallet upgrade in progress");

    newInsuranceFundWallet = self.currentInsuranceFundWalletUpgrade.newInsuranceFundWallet;

    delete self.currentInsuranceFundWalletUpgrade;
  }

  // solhint-disable-next-line func-name-mixedcase
  function finalizeInsuranceFundWalletUpgrade_delegatecall(
    Storage storage self,
    address newInsuranceFundWallet
  ) public {
    require(self.currentInsuranceFundWalletUpgrade.exists, "No IF wallet upgrade in progress");
    require(
      self.currentInsuranceFundWalletUpgrade.newInsuranceFundWallet == newInsuranceFundWallet,
      "Address mismatch"
    );
    require(block.number >= self.currentInsuranceFundWalletUpgrade.blockThreshold, "Block threshold not yet reached");

    delete (self.currentInsuranceFundWalletUpgrade);
  }

  function initiateMarketOverridesUpgrade(
    Storage storage self,
    string memory baseAssetSymbol,
    OverridableMarketFields memory overridableFields,
    address wallet
  ) internal returns (uint256 blockThreshold) {
    require(
      !self.currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet[baseAssetSymbol][wallet].exists,
      "Market override upgrade already in progress for wallet"
    );

    blockThreshold = block.number + Constants.FIELD_UPGRADE_DELAY_IN_BLOCKS;
    self.currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet[baseAssetSymbol][wallet] = MarketOverridesUpgrade(
      true,
      overridableFields,
      blockThreshold
    );
  }

  function cancelMarketOverridesUpgrade(Storage storage self, string memory baseAssetSymbol, address wallet) internal {
    require(
      self.currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet[baseAssetSymbol][wallet].exists,
      "No market override upgrade in progress for wallet"
    );

    delete self.currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet[baseAssetSymbol][wallet];
  }

  function finalizeMarketOverridesUpgrade(
    Storage storage self,
    string memory baseAssetSymbol,
    address wallet
  ) internal returns (OverridableMarketFields memory marketOverrides) {
    MarketOverridesUpgrade storage upgrade = self.currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet[
      baseAssetSymbol
    ][wallet];
    require(upgrade.exists, "No market override upgrade in progress for wallet");
    require(block.number >= upgrade.blockThreshold, "Block threshold not yet reached");

    marketOverrides = upgrade.newMarketOverrides;

    delete (self.currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet[baseAssetSymbol][wallet]);
  }
}
