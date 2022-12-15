// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AssetUnitConversions } from "./AssetUnitConversions.sol";
import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { ICustodian } from "./Interfaces.sol";

library Depositing {
  using BalanceTracking for BalanceTracking.Storage;

  // solhint-disable-next-line func-name-mixedcase
  function deposit_delegatecall(
    address wallet,
    uint256 quantityInAssetUnits,
    address quoteAssetAddress,
    ICustodian custodian,
    BalanceTracking.Storage storage balanceTracking
  ) public returns (uint64 quantity, int64 newExchangeBalance) {
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
    IERC20(quoteAssetAddress).transferFrom(wallet, address(custodian), quantityInAssetUnitsWithoutFractionalPips);

    // Update balance with actual transferred quantity
    newExchangeBalance = balanceTracking.updateForDeposit(wallet, Constants.QUOTE_ASSET_SYMBOL, quantity);
  }
}
