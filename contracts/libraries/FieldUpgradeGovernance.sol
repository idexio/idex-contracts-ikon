// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Constants } from "./Constants.sol";
import { OverridableMarketFields } from "./Structs.sol";

library FieldUpgradeGovernance {
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
    InsuranceFundWalletUpgrade currentInsuranceFundWalletUpgrade;
    mapping(string => mapping(address => MarketOverridesUpgrade)) currentMarketOverridesUpgradesByBaseAssetSymbolAndWallet;
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
