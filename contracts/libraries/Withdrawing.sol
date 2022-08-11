// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.15;

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
    address collateralAssetAddress;
    uint8 collateralAssetDecimals;
    string collateralAssetSymbol;
    ICustodian custodian;
    address feeWallet;
    address oracleWalletAddress;
  }

  struct WithdrawExitArguments {
    // External arguments
    OraclePrice[] oraclePrices;
    // Exchange state
    address collateralAssetAddress;
    uint8 collateralAssetDecimals;
    string collateralAssetSymbol;
    ICustodian custodian;
    address exitFundWallet;
    address oracleWalletAddress;
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
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
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
      arguments.collateralAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    // Update wallet balances
    newExchangeBalanceInPips = balanceTracking.updateForWithdrawal(
      arguments.withdrawal,
      arguments.collateralAssetSymbol,
      arguments.feeWallet
    );

    require(
      Margin.isInitialMarginRequirementMetAndUpdateLastOraclePrice(
        Margin.LoadMarginRequirementArguments(
          arguments.withdrawal.walletAddress,
          arguments.oraclePrices,
          arguments.oracleWalletAddress,
          arguments.collateralAssetDecimals,
          arguments.collateralAssetSymbol
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
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

  function withdrawExit(
    WithdrawExitArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) public returns (uint64) {
    Funding.updateWalletFunding(
      msg.sender,
      arguments.collateralAssetSymbol,
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
      marketsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    Balance storage balance = balanceTracking.loadBalanceAndMigrateIfNeeded(
      msg.sender,
      arguments.collateralAssetSymbol
    );
    quoteQuantityInPips += balance.balanceInPips;
    balance.balanceInPips = 0;

    require(quoteQuantityInPips > 0, 'Negative collateral after exit');

    arguments.custodian.withdraw(
      msg.sender,
      arguments.collateralAssetAddress,
      AssetUnitConversions.pipsToAssetUnits(
        uint64(quoteQuantityInPips),
        arguments.collateralAssetDecimals
      )
    );

    return uint64(quoteQuantityInPips);
  }

  function updatePositionsForExit(
    WithdrawExitArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) private returns (int64 quoteQuantityInPips) {
    (
      int64 totalAccountValueInPips,
      uint64 totalMaintenanceMarginRequirementInPips
    ) = loadTotalAccountValueAndMarginRequirement(
        arguments,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
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
        msg.sender,
        market.baseAssetSymbol,
        arguments.exitFundWallet,
        Margin.loadMaintenanceMarginFractionInPips(
          market,
          msg.sender,
          marketOverridesByBaseAssetSymbolAndWallet
        ),
        Validations.validateOraclePriceAndConvertToPips(
          arguments.oraclePrices[i],
          arguments.collateralAssetDecimals,
          market,
          arguments.oracleWalletAddress
        ),
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips
      );
    }

    // Quote out from exit fund wallet
    Balance storage balance = balanceTracking.loadBalanceAndMigrateIfNeeded(
      arguments.exitFundWallet,
      arguments.collateralAssetSymbol
    );
    balance.balanceInPips -= quoteQuantityInPips;
  }

  function loadTotalAccountValueAndMarginRequirement(
    WithdrawExitArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(string => mapping(address => Market))
      storage marketOverridesByBaseAssetSymbolAndWallet
  ) private returns (int64, uint64) {
    int64 totalAccountValueInPips = Margin.loadTotalAccountValue(
      Margin.LoadMarginRequirementArguments(
        msg.sender,
        arguments.oraclePrices,
        arguments.oracleWalletAddress,
        arguments.collateralAssetDecimals,
        arguments.collateralAssetSymbol
      ),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    uint64 totalMaintenanceMarginRequirementInPips = Margin
      .loadTotalMaintenanceMarginRequirementAndUpdateLastOraclePrice(
        Margin.LoadMarginRequirementArguments(
          msg.sender,
          arguments.oraclePrices,
          arguments.oracleWalletAddress,
          arguments.collateralAssetDecimals,
          arguments.collateralAssetSymbol
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol,
        marketOverridesByBaseAssetSymbolAndWallet
      );

    return (totalAccountValueInPips, totalMaintenanceMarginRequirementInPips);
  }
}
