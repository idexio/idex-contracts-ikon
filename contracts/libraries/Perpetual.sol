// SPDX-License-Identifier: LGPL-3.0-only

import { AssetUnitConversions } from './AssetUnitConversions.sol';
import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { Funding } from './Funding.sol';
import { FundingMultipliers } from './FundingMultipliers.sol';
import { Liquidation } from './Liquidation.sol';
import { Margin } from './Margin.sol';
import { Math } from './Math.sol';
import { String } from './String.sol';
import { Validations } from './Validations.sol';
import { Balance, FundingMultiplierQuartet, Market, OraclePrice } from './Structs.sol';

pragma solidity 0.8.15;

// TODO Gas optimization - several of the functions here iterate over all a wallet's position, potentially these
// multiple iterations could be combined
library Perpetual {
  using BalanceTracking for BalanceTracking.Storage;

  function loadOutstandingWalletFunding(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsBySymbol,
    mapping(address => string[]) storage marketSymbolsWithOpenPositionsByWallet
  ) public view returns (int64 fundingInPips) {
    return
      Funding.loadOutstandingWalletFunding(
        wallet,
        balanceTracking,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsBySymbol,
        marketSymbolsWithOpenPositionsByWallet
      );
  }

  function loadTotalAccountValueIncludingOutstandingWalletFunding(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 collateralAssetDecimals,
    string memory collateralAssetSymbol,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsBySymbol,
    mapping(address => string[]) storage marketSymbolsWithOpenPositionsByWallet
  ) public view returns (int64) {
    return
      Margin.loadTotalAccountValue(
        wallet,
        oraclePrices,
        collateralAssetDecimals,
        collateralAssetSymbol,
        oracleWalletAddress,
        balanceTracking,
        marketsBySymbol,
        marketSymbolsWithOpenPositionsByWallet
      ) +
      loadOutstandingWalletFunding(
        wallet,
        balanceTracking,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsBySymbol,
        marketSymbolsWithOpenPositionsByWallet
      );
  }

  function loadTotalInitialMarginRequirement(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 collateralAssetDecimals,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => Market) storage marketsBySymbol,
    mapping(address => string[]) storage marketSymbolsWithOpenPositionsByWallet
  ) public view returns (uint64 initialMarginRequirement) {
    return
      Margin.loadTotalInitialMarginRequirement(
        wallet,
        oraclePrices,
        collateralAssetDecimals,
        oracleWalletAddress,
        balanceTracking,
        marketsBySymbol,
        marketSymbolsWithOpenPositionsByWallet
      );
  }

  function loadTotalMaintenanceMarginRequirement(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 collateralAssetDecimals,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => Market) storage marketsBySymbol,
    mapping(address => string[]) storage marketSymbolsWithOpenPositionsByWallet
  ) public view returns (uint64 initialMarginRequirement) {
    return
      Margin.loadTotalMaintenanceMarginRequirement(
        wallet,
        oraclePrices,
        collateralAssetDecimals,
        oracleWalletAddress,
        balanceTracking,
        marketsBySymbol,
        marketSymbolsWithOpenPositionsByWallet
      );
  }

  function liquidate(
    Liquidation.LiquidateArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsBySymbol,
    mapping(address => string[]) storage marketSymbolsWithOpenPositionsByWallet
  ) public {
    Funding.updateWalletFunding(
      arguments.walletAddress,
      arguments.collateralAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsBySymbol,
      marketSymbolsWithOpenPositionsByWallet
    );

    Liquidation.liquidate(
      arguments,
      balanceTracking,
      marketsBySymbol,
      marketSymbolsWithOpenPositionsByWallet
    );
  }

  function publishFundingMutipliers(
    OraclePrice[] memory oraclePrices,
    int64[] memory fundingRatesInPips,
    uint8 collateralAssetDecimals,
    address oracleWalletAddress,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol
  ) public {
    Funding.publishFundingMutipliers(
      oraclePrices,
      fundingRatesInPips,
      collateralAssetDecimals,
      oracleWalletAddress,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol
    );
  }

  function updateWalletFunding(
    address wallet,
    string memory collateralAssetSymbol,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsBySymbol,
    mapping(address => string[]) storage marketSymbolsWithOpenPositionsByWallet
  ) public {
    Funding.updateWalletFunding(
      wallet,
      collateralAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsBySymbol,
      marketSymbolsWithOpenPositionsByWallet
    );
  }
}
