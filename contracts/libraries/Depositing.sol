// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AssetUnitConversions } from "./AssetUnitConversions.sol";
import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { ICustodian } from "./Interfaces.sol";
import { WalletExit } from "./Structs.sol";

library Depositing {
  using BalanceTracking for BalanceTracking.Storage;

  // solhint-disable-next-line func-name-mixedcase
  function deposit_delegatecall(
    ICustodian custodian,
    uint64 depositIndex,
    address destinationWallet,
    address exitFundWallet,
    uint256 quantityInAssetUnits,
    address quoteTokenAddress,
    address sourceWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => WalletExit) storage walletExits
  ) public returns (uint64 quantity, int64 newExchangeBalance) {
    // Deposits are disabled until `setDepositIndex` is called successfully
    require(depositIndex != Constants.DEPOSIT_INDEX_NOT_SET, "Deposits disabled");
    require(destinationWallet != exitFundWallet, "Cannot deposit to EF");

    // Calling exitWallet disables deposits immediately on mining, in contrast to withdrawals and trades which respect
    // the Chain Propagation Period given by `effectiveBlockNumber` via `_isWalletExitFinalized`
    require(!walletExits[sourceWallet].exists, "Source wallet exited");
    require(!walletExits[destinationWallet].exists, "Destination wallet exited");

    quantity = AssetUnitConversions.assetUnitsToPips(quantityInAssetUnits, Constants.QUOTE_TOKEN_DECIMALS);
    require(quantity > 0, "Quantity is too low");
    require(quantity < uint64(type(int64).max), "Quantity is too large");

    // Convert from pips back into asset units to remove any fractional amount that is too small
    // to express in pips. The `Exchange` will call `transferFrom` without this fractional amount
    // and there will be no dust
    uint256 quantityInAssetUnitsWithoutFractionalPips = AssetUnitConversions.pipsToAssetUnits(
      quantity,
      Constants.QUOTE_TOKEN_DECIMALS
    );

    uint256 balanceBefore = IERC20(quoteTokenAddress).balanceOf(address(custodian));

    // Forward the funds to the `Custodian`
    IERC20(quoteTokenAddress).transferFrom(sourceWallet, address(custodian), quantityInAssetUnitsWithoutFractionalPips);

    uint256 balanceAfter = IERC20(quoteTokenAddress).balanceOf(address(custodian));

    // Support fee-on-transfer by only crediting actual token balance difference. If fee causes transferred amount to
    // have a fractional pip component, it will accumulate as dust in the Custodian
    uint64 quantityTransferred = AssetUnitConversions.assetUnitsToPips(
      balanceAfter - balanceBefore,
      Constants.QUOTE_TOKEN_DECIMALS
    );

    // Update balance with actual transferred quantity
    newExchangeBalance = balanceTracking.updateForDeposit(destinationWallet, quantityTransferred);
  }
}
