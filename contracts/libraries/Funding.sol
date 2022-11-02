// SPDX-License-Identifier: LGPL-3.0-only

import { BalanceTracking } from './BalanceTracking.sol';
import { Constants } from './Constants.sol';
import { FundingMultipliers } from './FundingMultipliers.sol';
import { Math } from './Math.sol';
import { Margin } from './Margin.sol';
import { Validations } from './Validations.sol';
import { Balance, FundingMultiplierQuartet, Market, OraclePrice } from './Structs.sol';

pragma solidity 0.8.17;

library Funding {
  using BalanceTracking for BalanceTracking.Storage;
  using FundingMultipliers for FundingMultiplierQuartet[];

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
      loadOutstandingWalletFundingInternal(
        wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsByBaseAssetSymbol
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
      loadOutstandingWalletFundingInternal(
        arguments.wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsByBaseAssetSymbol
      );
  }

  function loadOutstandingWalletFundingInternal(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64 fundingInPips) {
    int64 marketFundingInPips;

    string[] memory marketSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
      wallet
    ];
    for (
      uint8 marketIndex = 0;
      marketIndex < marketSymbols.length;
      marketIndex++
    ) {
      Market memory market = marketsByBaseAssetSymbol[
        marketSymbols[marketIndex]
      ];
      Balance memory basePosition = balanceTracking
        .loadBalanceFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol);

      (marketFundingInPips, ) = loadWalletFundingForMarket(
        basePosition,
        market,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol
      );
      fundingInPips += marketFundingInPips;
    }
  }

  function loadWalletFundingForMarket(
    Balance memory basePosition,
    Market memory market,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol
  )
    internal
    view
    returns (int64 fundingInPips, uint64 lastFundingMultiplierTimestampInMs)
  {
    // Load funding rates and index
    FundingMultiplierQuartet[]
      storage fundingMultipliersForMarket = fundingMultipliersByBaseAssetSymbol[
        market.baseAssetSymbol
      ];
    lastFundingMultiplierTimestampInMs = lastFundingRatePublishTimestampInMsByBaseAssetSymbol[
      market.baseAssetSymbol
    ];

    // Apply hourly funding payments if new rates were published since this balance was last updated
    if (
      basePosition.balanceInPips != 0 &&
      basePosition.lastUpdateTimestampInMs < lastFundingMultiplierTimestampInMs
    ) {
      int64 aggregateFundingMultiplier = fundingMultipliersForMarket
        .loadAggregateMultiplier(
          basePosition.lastUpdateTimestampInMs,
          lastFundingMultiplierTimestampInMs
        );

      fundingInPips += Math.multiplyPipsByFraction(
        basePosition.balanceInPips,
        aggregateFundingMultiplier,
        int64(Constants.pipPriceMultiplier)
      );
    }
  }

  function publishFundingMutipliers(
    int64[] memory fundingRatesInPips,
    OraclePrice[] memory oraclePrices,
    address oracleWallet,
    uint8 quoteAssetDecimals,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol
  ) public {
    for (uint8 i = 0; i < oraclePrices.length; i++) {
      (OraclePrice memory oraclePrice, int64 fundingRateInPips) = (
        oraclePrices[i],
        fundingRatesInPips[i]
      );
      uint64 oraclePriceInPips = Validations
        .validateOraclePriceAndConvertToPips(
          oraclePrice,
          quoteAssetDecimals,
          oracleWallet
        );

      uint64 lastPublishTimestampInMs = lastFundingRatePublishTimestampInMsByBaseAssetSymbol[
          oraclePrice.baseAssetSymbol
        ];
      require(
        lastPublishTimestampInMs > 0
          ? lastPublishTimestampInMs + Constants.msInOneHour ==
            oraclePrice.timestampInMs
          : oraclePrice.timestampInMs % Constants.msInOneHour == 0,
        'Input price not hour-aligned'
      );

      // TODO Cleanup typecasts
      int64 newFundingMultiplier = Math.multiplyPipsByFraction(
        int64(oraclePriceInPips),
        fundingRateInPips,
        int64(Constants.pipPriceMultiplier)
      );

      fundingMultipliersByBaseAssetSymbol[oraclePrice.baseAssetSymbol]
        .publishFundingMultipler(newFundingMultiplier);

      lastFundingRatePublishTimestampInMsByBaseAssetSymbol[
        oraclePrice.baseAssetSymbol
      ] = oraclePrice.timestampInMs;
    }
  }

  function updateWalletFunding(
    address wallet,
    string memory quoteAssetSymbol,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    updateWalletFundingInternal(
      wallet,
      quoteAssetSymbol,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
  }

  function updateWalletFundingInternal(
    address wallet,
    string memory quoteAssetSymbol,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[])
      storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[])
      storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64)
      storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal {
    int64 fundingInPips;
    int64 marketFundingInPips;
    uint64 lastFundingMultiplierTimestampInMs;

    string[] memory marketSymbols = baseAssetSymbolsWithOpenPositionsByWallet[
      wallet
    ];
    for (
      uint8 marketIndex = 0;
      marketIndex < marketSymbols.length;
      marketIndex++
    ) {
      Market memory market = marketsByBaseAssetSymbol[
        marketSymbols[marketIndex]
      ];
      Balance storage basePosition = balanceTracking
        .loadBalanceAndMigrateIfNeeded(wallet, market.baseAssetSymbol);

      (
        marketFundingInPips,
        lastFundingMultiplierTimestampInMs
      ) = loadWalletFundingForMarket(
        basePosition,
        market,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol
      );
      fundingInPips += marketFundingInPips;
      basePosition.lastUpdateTimestampInMs = lastFundingMultiplierTimestampInMs;
    }

    Balance storage quoteBalance = balanceTracking
      .loadBalanceAndMigrateIfNeeded(wallet, quoteAssetSymbol);
    quoteBalance.balanceInPips += fundingInPips;
  }
}
