// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { Constants } from "./Constants.sol";

library InsuranceFundWalletUpgrade {
  struct Storage {
    bool exists;
    address newInsuranceFundWallet;
    uint256 blockThreshold;
  }

  // solhint-disable-next-line func-name-mixedcase
  function initiateInsuranceFundWalletUpgrade_delegatecall(
    Storage storage self,
    address currentInsuranceFundWallet,
    address newInsuranceFundWallet
  ) public {
    require(newInsuranceFundWallet != address(0x0), "Invalid IF wallet address");
    require(newInsuranceFundWallet != currentInsuranceFundWallet, "Must be different from current");
    require(!self.exists, "IF wallet upgrade already in progress");

    self.exists = true;
    self.newInsuranceFundWallet = newInsuranceFundWallet;
    self.blockThreshold = block.number + Constants.INSURANCE_FUND_WALLET_UPGRADE_DELAY_IN_BLOCKS;
  }

  // solhint-disable-next-line func-name-mixedcase
  function cancelInsuranceFundWalletUpgrade_delegatecall(
    Storage storage self
  ) public returns (address newInsuranceFundWallet) {
    require(self.exists, "No IF wallet upgrade in progress");

    newInsuranceFundWallet = self.newInsuranceFundWallet;
    _clear(self);
  }

  // solhint-disable-next-line func-name-mixedcase
  function finalizeInsuranceFundWalletUpgrade_delegatecall(
    Storage storage self,
    address newInsuranceFundWallet
  ) public {
    require(self.exists, "No IF wallet upgrade in progress");
    require(self.newInsuranceFundWallet == newInsuranceFundWallet, "Address mismatch");
    require(block.number >= self.blockThreshold, "Block threshold not yet reached");

    _clear(self);
  }

  // The below is a workaround to Solidity not allowing assignment to self storage pointer directly
  function _clear(Storage storage self) private {
    self.exists = false;
    self.newInsuranceFundWallet = address(0x0);
    self.blockThreshold = 0;
  }
}
