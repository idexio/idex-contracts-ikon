// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.13;

import { AssetUnitConversions } from './AssetUnitConversions.sol';
import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { ICustodian } from './Interfaces.sol';
import { Withdrawal } from './Structs.sol';
import { Validations } from './Validations.sol';

library Withdrawing {
  using BalanceTracking for BalanceTracking.Storage;

  function withdraw(
    Withdrawal memory withdrawal,
    address collateralAssetAddress,
    string memory collateralAssetSymbol,
    uint8 collateralAssetDecimals,
    ICustodian custodian,
    address feeWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(bytes32 => bool) storage completedWithdrawalHashes
  ) public returns (int64 newExchangeBalanceInPips) {
    // Validations
    require(
      Validations.isFeeQuantityValid(
        withdrawal.gasFeeInPips,
        withdrawal.grossQuantityInPips,
        Constants.maxFeeBasisPoints
      ),
      'Excessive withdrawal fee'
    );
    bytes32 withdrawalHash = Validations.validateWithdrawalSignature(
      withdrawal
    );
    require(
      !completedWithdrawalHashes[withdrawalHash],
      'Hash already withdrawn'
    );

    // Update wallet balances
    newExchangeBalanceInPips = balanceTracking.updateForWithdrawal(
      withdrawal,
      collateralAssetSymbol,
      feeWallet
    );

    // Transfer funds from Custodian to wallet
    uint256 netAssetQuantityInAssetUnits = AssetUnitConversions
      .pipsToAssetUnits(
        withdrawal.grossQuantityInPips - withdrawal.gasFeeInPips,
        collateralAssetDecimals
      );
    custodian.withdraw(
      withdrawal.walletAddress,
      collateralAssetAddress,
      netAssetQuantityInAssetUnits
    );

    // Replay prevention
    completedWithdrawalHashes[withdrawalHash] = true;
  }
}
