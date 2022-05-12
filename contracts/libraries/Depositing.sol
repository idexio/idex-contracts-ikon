// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.13;

import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import { AssetUnitConversions } from './AssetUnitConversions.sol';
import { BalanceTracking } from './BalanceTracking.sol';
import { ICustodian } from './Interfaces.sol';

library Depositing {
  using BalanceTracking for BalanceTracking.Storage;

  function deposit(
    address wallet,
    uint256 quantityInAssetUnits,
    address collateralAssetAddress,
    string memory collateralAssetSymbol,
    uint8 collateralAssetDecimals,
    ICustodian custodian,
    BalanceTracking.Storage storage balanceTracking
  ) public returns (uint64 quantityInPips, int64 newExchangeBalanceInPips) {
    quantityInPips = AssetUnitConversions.assetUnitsToPips(
      quantityInAssetUnits,
      collateralAssetDecimals
    );
    require(quantityInPips > 0, 'Quantity is too low');

    // Convert from pips back into asset units to remove any fractional amount that is too small
    // to express in pips. The `Exchange` will call `transferFrom` without this fractional amount
    // and there will be no dust
    uint256 quantityInAssetUnitsWithoutFractionalPips = AssetUnitConversions
      .pipsToAssetUnits(quantityInPips, collateralAssetDecimals);

    // Forward the funds to the `Custodian`
    IERC20(collateralAssetAddress).transferFrom(
      wallet,
      address(custodian),
      quantityInAssetUnitsWithoutFractionalPips
    );

    // Update balance with actual transferred quantity
    newExchangeBalanceInPips = balanceTracking.updateForDeposit(
      wallet,
      collateralAssetSymbol,
      quantityInPips
    );
  }
}
