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
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (int64 fundingInPips) {
    return
      Funding.loadOutstandingWalletFunding(
        wallet,
        balanceTracking,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsByBaseAssetSymbol,
        baseAssetSymbolsWithOpenPositionsByWallet
      );
  }

  function loadTotalAccountValueIncludingOutstandingWalletFunding(
    Margin.LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (int64) {
    return
      Margin.loadTotalAccountValue(
        arguments,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      ) +
      loadOutstandingWalletFunding(
        arguments.wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsByBaseAssetSymbol
      );
  }

  function loadTotalInitialMarginRequirement(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 quoteAssetDecimals,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet
  ) public view returns (uint64 initialMarginRequirement) {
    return
      Margin.loadTotalInitialMarginRequirement(
        wallet,
        oraclePrices,
        quoteAssetDecimals,
        oracleWalletAddress,
        balanceTracking,
        marketsByBaseAssetSymbol,
        baseAssetSymbolsWithOpenPositionsByWallet
      );
  }

  function loadTotalMaintenanceMarginRequirement(
    address wallet,
    OraclePrice[] memory oraclePrices,
    uint8 quoteAssetDecimals,
    address oracleWalletAddress,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet
  ) public view returns (uint64 initialMarginRequirement) {
    return
      Margin.loadTotalMaintenanceMarginRequirement(
        wallet,
        oraclePrices,
        quoteAssetDecimals,
        oracleWalletAddress,
        balanceTracking,
        marketsByBaseAssetSymbol,
        baseAssetSymbolsWithOpenPositionsByWallet
      );
  }

  function liquidateWallet(
    Liquidation.LiquidateWalletArguments memory arguments,
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
  ) public {
    Funding.updateWalletFunding(
      arguments.liquidatingWallet,
      arguments.quoteAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    Liquidation.liquidateWallet(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function liquidationAcquisitionDeleverage(
    Liquidation.DeleveragePositionArguments memory arguments,
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
  ) public {
    Funding.updateWalletFunding(
      arguments.deleveragingWallet,
      arguments.quoteAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol,
      baseAssetSymbolsWithOpenPositionsByWallet
    );
    Funding.updateWalletFunding(
      arguments.liquidatingWallet,
      arguments.quoteAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    Liquidation.liquidationAcquisitionDeleverage(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function liquidationClosureDeleverage(
    Liquidation.DeleveragePositionArguments memory arguments,
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
  ) public {
    Funding.updateWalletFunding(
      arguments.deleveragingWallet,
      arguments.quoteAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol,
      baseAssetSymbolsWithOpenPositionsByWallet
    );

    Liquidation.liquidationClosureDeleverage(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function publishFundingMutipliers(
    OraclePrice[] memory oraclePrices,
    int64[] memory fundingRatesInPips,
    uint8 quoteAssetDecimals,
    address oracleWalletAddress,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol
  ) public {
    Funding.publishFundingMutipliers(
      oraclePrices,
      fundingRatesInPips,
      quoteAssetDecimals,
      oracleWalletAddress,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol
    );
  }

  function updateWalletFunding(
    address wallet,
    string memory quoteAssetSymbol,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet
  ) public {
    Funding.updateWalletFunding(
      wallet,
      quoteAssetSymbol,
      balanceTracking,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol,
      baseAssetSymbolsWithOpenPositionsByWallet
    );
  }
}
