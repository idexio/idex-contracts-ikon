// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { AssetUnitConversions } from './AssetUnitConversions.sol';
import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { ICustodian } from './Interfaces.sol';
import { Funding } from './Funding.sol';
import { Liquidation } from './Liquidation.sol';
import { Margin } from './Margin.sol';
import { Math } from './Math.sol';
import { Validations } from './Validations.sol';
import { Balance, FundingMultiplierQuartet, Market, OraclePrice, Withdrawal } from './Structs.sol';

library Withdrawing {
  using BalanceTracking for BalanceTracking.Storage;

  struct WithdrawArguments {
    // External arguments
    Withdrawal withdrawal;
    OraclePrice[] oraclePrices;
    // Exchange state
    address quoteAssetAddress;
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
    ICustodian custodian;
    address feeWallet;
    address oracleWallet;
  }

  struct WithdrawExitArguments {
    // External arguments
    address wallet;
    OraclePrice[] oraclePrices;
    // Exchange state
    ICustodian custodian;
    address exitFundWallet;
    address oracleWallet;
    address quoteAssetAddress;
    uint8 quoteAssetDecimals;
    string quoteAssetSymbol;
  }

  function withdraw(
    WithdrawArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(bytes32 => bool) storage completedWithdrawalHashes,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
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

    Funding.updateWalletFunding(
      arguments.withdrawal.walletAddress,
      arguments.quoteAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Update wallet balances
    newExchangeBalanceInPips = balanceTracking.updateForWithdrawal(
      arguments.withdrawal,
      arguments.quoteAssetSymbol,
      arguments.feeWallet
    );

    require(
      Margin.isInitialMarginRequirementMetAndUpdateLastOraclePrice(
        Margin.LoadArguments(
          arguments.withdrawal.walletAddress,
          arguments.oraclePrices,
          arguments.oracleWallet,
          arguments.quoteAssetDecimals,
          arguments.quoteAssetSymbol
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      ),
      'Initial margin requirement not met for buy wallet'
    );

    // Transfer funds from Custodian to wallet
    uint256 netAssetQuantityInAssetUnits = AssetUnitConversions
      .pipsToAssetUnits(
        arguments.withdrawal.grossQuantityInPips -
          arguments.withdrawal.gasFeeInPips,
        arguments.quoteAssetDecimals
      );
    arguments.custodian.withdraw(
      arguments.withdrawal.walletAddress,
      arguments.quoteAssetAddress,
      netAssetQuantityInAssetUnits
    );

    // Replay prevention
    completedWithdrawalHashes[withdrawalHash] = true;
  }

  function withdrawExit(
    WithdrawExitArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public returns (uint64) {
    Funding.updateWalletFunding(
      arguments.wallet,
      arguments.quoteAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    int64 quoteQuantityInPips = updatePositionsForExit(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    Balance storage balance = balanceTracking.loadBalanceAndMigrateIfNeeded(
      arguments.wallet,
      arguments.quoteAssetSymbol
    );
    quoteQuantityInPips += balance.balanceInPips;
    balance.balanceInPips = 0;

    require(quoteQuantityInPips > 0, 'Negative quote after exit');

    arguments.custodian.withdraw(
      arguments.wallet,
      arguments.quoteAssetAddress,
      AssetUnitConversions.pipsToAssetUnits(
        uint64(quoteQuantityInPips),
        arguments.quoteAssetDecimals
      )
    );

    return uint64(quoteQuantityInPips);
  }

  function updatePositionsForExit(
    WithdrawExitArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private returns (int64 quoteQuantityInPips) {
    (
      int64 totalAccountValueInPips,
      uint64 totalMaintenanceMarginRequirementInPips
    ) = loadTotalAccountValueAndMarginRequirement(
        arguments,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );

    for (
      uint8 i = 0;
      i < baseAssetSymbolsWithOpenPositionsByWallet[msg.sender].length;
      i++
    ) {
      Market memory market = marketsByBaseAssetSymbol[
        baseAssetSymbolsWithOpenPositionsByWallet[msg.sender][i]
      ];
      quoteQuantityInPips += balanceTracking.updateForExit(
        arguments.exitFundWallet,
        market,
        Validations.validateOraclePriceAndConvertToPips(
          arguments.oraclePrices[i],
          arguments.quoteAssetDecimals,
          market,
          arguments.oracleWallet
        ),
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips,
        msg.sender,
        marketOverridesByBaseAssetSymbolAndWallet
      );
    }

    // Quote out from exit fund wallet
    Balance storage balance = balanceTracking.loadBalanceAndMigrateIfNeeded(
      arguments.exitFundWallet,
      arguments.quoteAssetSymbol
    );
    balance.balanceInPips -= quoteQuantityInPips;
  }

  function loadTotalAccountValueAndMarginRequirement(
    WithdrawExitArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private returns (int64, uint64) {
    int64 totalAccountValueInPips = Margin.loadTotalWalletExitAccountValue(
      Margin.LoadArguments(
        msg.sender,
        arguments.oraclePrices,
        arguments.oracleWallet,
        arguments.quoteAssetDecimals,
        arguments.quoteAssetSymbol
      ),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    uint64 totalMaintenanceMarginRequirementInPips = Margin
      .loadTotalMaintenanceMarginRequirementAndUpdateLastOraclePrice(
        Margin.LoadArguments(
          msg.sender,
          arguments.oraclePrices,
          arguments.oracleWallet,
          arguments.quoteAssetDecimals,
          arguments.quoteAssetSymbol
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );

    return (totalAccountValueInPips, totalMaintenanceMarginRequirementInPips);
  }
}
