// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AssetUnitConversions } from "./AssetUnitConversions.sol";
import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { Exiting } from "./Exiting.sol";
import { ICustodian } from "./Interfaces.sol";

library Depositing {
  using BalanceTracking for BalanceTracking.Storage;

  // solhint-disable-next-line func-name-mixedcase
  function deposit_delegatecall(
    ICustodian custodian,
    uint64 depositIndex,
    uint256 quantityInAssetUnits,
    address quoteAssetAddress,
    address sourceWallet,
    address destinationWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => Exiting.WalletExit) storage walletExits
  ) public returns (uint64 quantity, int64 newExchangeBalance) {
    // Deposits are disabled until `setDepositIndex` is called successfully
    require(depositIndex != Constants.DEPOSIT_INDEX_NOT_SET, "Deposits disabled");

    // Calling exitWallet disables deposits immediately on mining, in contrast to withdrawals and trades which respect
    // the Chain Propagation Period given by `effectiveBlockNumber` via `_isWalletExitFinalized`
    require(!walletExits[sourceWallet].exists, "Source wallet exited");
    require(!walletExits[destinationWallet].exists, "Destination wallet exited");

    quantity = AssetUnitConversions.assetUnitsToPips(quantityInAssetUnits, Constants.QUOTE_ASSET_DECIMALS);
    require(quantity > 0, "Quantity is too low");

    // Convert from pips back into asset units to remove any fractional amount that is too small
    // to express in pips. The `Exchange` will call `transferFrom` without this fractional amount
    // and there will be no dust
    uint256 quantityInAssetUnitsWithoutFractionalPips = AssetUnitConversions.pipsToAssetUnits(
      quantity,
      Constants.QUOTE_ASSET_DECIMALS
    );

    // Forward the funds to the `Custodian`
    IERC20(quoteAssetAddress).transferFrom(sourceWallet, address(custodian), quantityInAssetUnitsWithoutFractionalPips);

    // Update balance with actual transferred quantity
    newExchangeBalance = balanceTracking.updateForDeposit(destinationWallet, quantity);
  }
}
