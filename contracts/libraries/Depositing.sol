// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AssetUnitConversions } from "./AssetUnitConversions.sol";
import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { ICustodian } from "./Interfaces.sol";
import { WalletExit } from "./Structs.sol";

library Depositing {
  using BalanceTracking for BalanceTracking.Storage;

  struct DepositArguments {
    // External arguments
    address destinationWallet;
    address sourceWallet;
    uint256 quantityInAssetUnits;
    // Exchange state
    ICustodian custodian;
    uint64 depositIndex;
    address exitFundWallet;
    bool isDepositEnabled;
    address quoteTokenAddress;
  }

  /**
   * @notice Emitted when a user deposits quote tokens with `deposit`
   */
  event Deposited(uint64 index, address sourceWallet, address destinationWallet, uint64 quantity);

  /**
   * @notice Emitted when pending deposit quantity is applied via `applyPendingDepositsForWallet`
   */
  event PendingDepositApplied(address wallet, uint64 quantity, int64 newExchangeBalance);

  // solhint-disable-next-line func-name-mixedcase
  function deposit_delegatecall(
    DepositArguments memory arguments,
    mapping(address => uint64) storage pendingDepositQuantityByWallet,
    mapping(address => WalletExit) storage walletExits
  ) public {
    // Deposits are disabled until `setDepositIndex` is called successfully
    require(
      arguments.depositIndex != Constants.DEPOSIT_INDEX_NOT_SET && arguments.isDepositEnabled,
      "Deposits disabled"
    );
    require(arguments.destinationWallet != arguments.exitFundWallet, "Cannot deposit to EF");

    // Calling exitWallet disables deposits immediately on mining, in contrast to withdrawals and trades which respect
    // the Chain Propagation Period given by `effectiveBlockTimestamp` via `_isWalletExitFinalized`
    require(!walletExits[arguments.sourceWallet].exists, "Source wallet exited");
    require(!walletExits[arguments.destinationWallet].exists, "Destination wallet exited");

    uint64 quantity = AssetUnitConversions.assetUnitsToPips(
      arguments.quantityInAssetUnits,
      Constants.QUOTE_TOKEN_DECIMALS
    );

    require(quantity > 0, "Quantity is too low");
    require(quantity < uint64(type(int64).max), "Quantity is too large");

    // Convert from pips back into asset units to remove any fractional amount that is too small
    // to express in pips. The `Exchange` will call `transferFrom` without this fractional amount
    // and there will be no dust
    uint256 quantityInAssetUnitsWithoutFractionalPips = AssetUnitConversions.pipsToAssetUnits(
      quantity,
      Constants.QUOTE_TOKEN_DECIMALS
    );

    uint256 balanceBefore = IERC20(arguments.quoteTokenAddress).balanceOf(address(arguments.custodian));

    // Forward the funds to the `Custodian`
    IERC20(arguments.quoteTokenAddress).transferFrom(
      arguments.sourceWallet,
      address(arguments.custodian),
      quantityInAssetUnitsWithoutFractionalPips
    );

    uint256 balanceAfter = IERC20(arguments.quoteTokenAddress).balanceOf(address(arguments.custodian));

    // Support fee-on-transfer by only crediting actual token balance difference. If fee causes transferred amount to
    // have a fractional pip component, it will accumulate as dust in the Custodian
    uint64 quantityTransferred = AssetUnitConversions.assetUnitsToPips(
      balanceAfter - balanceBefore,
      Constants.QUOTE_TOKEN_DECIMALS
    );

    // Increment pending deposit quantity by actual transferred quantity
    pendingDepositQuantityByWallet[arguments.destinationWallet] += quantityTransferred;

    emit Deposited(
      // The Exchange will update the stored deposit index after this function returns
      arguments.depositIndex + 1,
      arguments.sourceWallet,
      arguments.destinationWallet,
      quantityTransferred
    );
  }

  // solhint-disable-next-line func-name-mixedcase
  function applyPendingDepositsForWallet_delegatecall(
    uint64 quantity,
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => uint64) storage pendingDepositQuantityByWallet
  ) public {
    uint64 pendingDepositQuantity = pendingDepositQuantityByWallet[wallet];
    require(quantity <= pendingDepositQuantity, "Quantity to apply exceeds pending");

    pendingDepositQuantityByWallet[wallet] = pendingDepositQuantity - quantity;

    // Update balance with argument quantity
    int64 newExchangeBalance = balanceTracking.updateForDeposit(wallet, quantity);

    emit PendingDepositApplied(wallet, quantity, newExchangeBalance);
  }
}
