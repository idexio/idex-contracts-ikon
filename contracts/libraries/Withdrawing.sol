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

    Funding.updateWalletFunding(
      arguments.withdrawal.walletAddress,
      arguments.collateralAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsBySymbol,
      marketSymbolsWithOpenPositionsByWallet
    );

    // Update wallet balances
    newExchangeBalanceInPips = balanceTracking.updateForWithdrawal(
      arguments.withdrawal,
      arguments.collateralAssetSymbol,
      arguments.feeWallet
    );

    require(
      Margin.isInitialMarginRequirementMetAndUpdateLastOraclePrice(
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

  // TODO Move to separate library, refactor updates to to BalanceTracking
  function withdrawExit(
    WithdrawExitArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsBySymbol,
    mapping(address => string[]) storage marketSymbolsWithOpenPositionsByWallet
  ) public returns (uint64) {
    Funding.updateWalletFunding(
      msg.sender,
      arguments.collateralAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsBySymbol,
      marketSymbolsWithOpenPositionsByWallet
    );

    int64 quoteQuantityInPips = updatePositionsForExit(
      arguments,
      balanceTracking,
      marketsBySymbol,
      marketSymbolsWithOpenPositionsByWallet
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
    mapping(string => Market) storage marketsBySymbol,
    mapping(address => string[]) storage marketSymbolsWithOpenPositionsByWallet
  ) private returns (int64 quoteQuantityInPips) {
    (
      int64 totalAccountValueInPips,
      uint64 totalMaintenanceMarginRequirementInPips
    ) = (
        Margin.loadTotalAccountValue(
          msg.sender,
          arguments.oraclePrices,
          arguments.collateralAssetDecimals,
          arguments.collateralAssetSymbol,
          arguments.oracleWalletAddress,
          balanceTracking,
          marketsBySymbol,
          marketSymbolsWithOpenPositionsByWallet
        ),
        Margin.loadTotalMaintenanceMarginRequirementAndUpdateLastOraclePrice(
          msg.sender,
          arguments.oraclePrices,
          arguments.collateralAssetDecimals,
          arguments.oracleWalletAddress,
          balanceTracking,
          marketsBySymbol,
          marketSymbolsWithOpenPositionsByWallet
        )
      );

    for (
      uint8 i = 0;
      i < marketSymbolsWithOpenPositionsByWallet[msg.sender].length;
      i++
    ) {
      quoteQuantityInPips += updateMarketPositionsForExit(
        arguments.exitFundWallet,
        marketsBySymbol[marketSymbolsWithOpenPositionsByWallet[msg.sender][i]],
        Validations.validateOraclePriceAndConvertToPips(
          arguments.oraclePrices[i],
          arguments.collateralAssetDecimals,
          marketsBySymbol[
            marketSymbolsWithOpenPositionsByWallet[msg.sender][i]
          ],
          arguments.oracleWalletAddress
        ),
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips,
        balanceTracking
      );
    }

    // Quote out from exit fund wallet
    Balance storage balance = balanceTracking.loadBalanceAndMigrateIfNeeded(
      arguments.exitFundWallet,
      arguments.collateralAssetSymbol
    );
    balance.balanceInPips -= quoteQuantityInPips;
  }

  function updateMarketPositionsForExit(
    address exitFundWallet,
    Market memory market,
    uint64 oraclePriceInPips,
    int64 totalAccountValueInPips,
    uint64 totalMaintenanceMarginRequirementInPips,
    BalanceTracking.Storage storage balanceTracking
  ) private returns (int64 quoteQuantityInPips) {
    Balance storage balance = balanceTracking.loadBalanceAndMigrateIfNeeded(
      msg.sender,
      market.baseAssetSymbol
    );
    int64 positionSizeInPips = balance.balanceInPips;

    quoteQuantityInPips = Math.multiplyPipsByFraction(
      positionSizeInPips,
      int64(oraclePriceInPips),
      int64(Constants.pipPriceMultiplier)
    );

    quoteQuantityInPips = Math.min(
      quoteQuantityInPips,
      balance.costBasisInPips
    );

    quoteQuantityInPips = Math.max(
      quoteQuantityInPips,
      Liquidation.calculateLiquidationQuoteQuantityInPips(
        positionSizeInPips,
        oraclePriceInPips,
        totalAccountValueInPips,
        totalMaintenanceMarginRequirementInPips,
        market.maintenanceMarginFractionInPips
      )
    );

    balance.balanceInPips = 0;
    balance.costBasisInPips = 0;

    balance = balanceTracking.loadBalanceAndMigrateIfNeeded(
      exitFundWallet,
      market.baseAssetSymbol
    );
    if (positionSizeInPips > 0) {
      BalanceTracking.subtractFromPosition(
        balance,
        Math.abs(positionSizeInPips),
        Math.abs(quoteQuantityInPips)
      );
    } else {
      BalanceTracking.addToPosition(
        balance,
        Math.abs(positionSizeInPips),
        Math.abs(quoteQuantityInPips)
      );
    }
  }
}
