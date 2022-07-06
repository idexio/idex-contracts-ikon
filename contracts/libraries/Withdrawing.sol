// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.15;

import { AssetUnitConversions } from './AssetUnitConversions.sol';
import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { ICustodian } from './Interfaces.sol';
import { Funding } from './Funding.sol';
import { Margin } from './Margin.sol';
import { Validations } from './Validations.sol';
import { FundingMultiplierQuartet, Market, OraclePrice, Withdrawal } from './Structs.sol';

library Withdrawing {
  using BalanceTracking for BalanceTracking.Storage;

  struct WithdrawArguments {
    // External arguments
    Withdrawal withdrawal;
    OraclePrice[] oraclePrices;
    // Exchange state
    address collateralAssetAddress;
    uint8 collateralAssetDecimals;
    string collateralAssetSymbol;
    ICustodian custodian;
    address feeWallet;
    address oracleWalletAddress;
  }

  function withdraw(
    WithdrawArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(bytes32 => bool) storage completedWithdrawalHashes,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsBySymbol,
    mapping(address => string[]) storage marketSymbolsWithOpenPositionsByWallet
  ) public returns (int64 newExchangeBalanceInPips) {
    // Validations
    require(
      Validations.isFeeQuantityValid(
        arguments.withdrawal.gasFeeInPips,
        arguments.withdrawal.grossQuantityInPips,
        Constants.maxFeeBasisPoints
      ),
      'Excessive withdrawal fee'
    );
    bytes32 withdrawalHash = Validations.validateWithdrawalSignature(
      arguments.withdrawal
    );
    require(
      !completedWithdrawalHashes[withdrawalHash],
      'Hash already withdrawn'
    );

    // Update wallet balances
    newExchangeBalanceInPips = balanceTracking.updateForWithdrawal(
      arguments.withdrawal,
      arguments.collateralAssetSymbol,
      arguments.feeWallet
    );

    Funding.updateWalletFunding(
      arguments.withdrawal.walletAddress,
      arguments.collateralAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsBySymbol,
      marketSymbolsWithOpenPositionsByWallet
    );

    require(
      Margin.isInitialMarginRequirementMet(
        arguments.withdrawal.walletAddress,
        arguments.oraclePrices,
        arguments.collateralAssetDecimals,
        arguments.collateralAssetSymbol,
        arguments.oracleWalletAddress,
        balanceTracking,
        marketsBySymbol,
        marketSymbolsWithOpenPositionsByWallet
      ),
      'Initial margin requirement not met for buy wallet'
    );

    // Transfer funds from Custodian to wallet
    uint256 netAssetQuantityInAssetUnits = AssetUnitConversions
      .pipsToAssetUnits(
        arguments.withdrawal.grossQuantityInPips -
          arguments.withdrawal.gasFeeInPips,
        arguments.collateralAssetDecimals
      );
    arguments.custodian.withdraw(
      arguments.withdrawal.walletAddress,
      arguments.collateralAssetAddress,
      netAssetQuantityInAssetUnits
    );

    // Replay prevention
    completedWithdrawalHashes[withdrawalHash] = true;
  }
}
