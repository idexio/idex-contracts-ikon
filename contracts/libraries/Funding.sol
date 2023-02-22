// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { FundingMultiplierQuartetHelper } from "./FundingMultiplierQuartetHelper.sol";
import { IndexPriceMargin } from "./IndexPriceMargin.sol";
import { Math } from "./Math.sol";
import { OraclePriceMargin } from "./OraclePriceMargin.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Time } from "./Time.sol";
import { Balance, FundingMultiplierQuartet, Market, MarketOverrides } from "./Structs.sol";

library Funding {
  using BalanceTracking for BalanceTracking.Storage;
  using FundingMultiplierQuartetHelper for FundingMultiplierQuartet[];
  using SortedStringSet for string[];

  // solhint-disable-next-line func-name-mixedcase
  function loadOutstandingWalletFunding_delegatecall(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (int64 funding) {
    return
      loadOutstandingWalletFunding(
        wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsByBaseAssetSymbol
      );
  }

  // solhint-disable-next-line func-name-mixedcase
  function loadQuoteQuantityAvailableForExitWithdrawalIncludingOutstandingWalletFunding_delegatecall(
    address exitFundWallet,
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (int64) {
    int64 outstandingWalletFunding = loadOutstandingWalletFunding(
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    return
      OraclePriceMargin.loadQuoteQuantityAvailableForExitWithdrawal(
        exitFundWallet,
        outstandingWalletFunding,
        wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
  }

  // solhint-disable-next-line func-name-mixedcase
  function loadTotalAccountValueIncludingOutstandingWalletFunding_delegatecall(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (int64) {
    int64 totalAccountValue = IndexPriceMargin.loadTotalAccountValue(
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    return
      totalAccountValue +
      loadOutstandingWalletFunding(
        wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsByBaseAssetSymbol
      );
  }

  // solhint-disable-next-line func-name-mixedcase
  function loadTotalAccountValueIncludingOutstandingWalletFundingFromOraclePriceFeed_delegatecall(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (int64) {
    int64 outstandingWalletFunding = loadOutstandingWalletFunding(
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    int64 totalAccountValue = OraclePriceMargin.loadTotalAccountValue(
      outstandingWalletFunding,
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    return
      totalAccountValue +
      loadOutstandingWalletFunding(
        wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsByBaseAssetSymbol
      );
  }

  // solhint-disable-next-line func-name-mixedcase
  function publishFundingMultiplier_delegatecall(
    string memory baseAssetSymbol,
    int64 fundingRate,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    Market memory market = marketsByBaseAssetSymbol[baseAssetSymbol];
    require(market.exists && market.isActive, "No active market found");

    uint64 lastPublishTimestampInMs = lastFundingRatePublishTimestampInMsByBaseAssetSymbol[baseAssetSymbol];

    uint64 nextPublishTimestampInMs;
    if (lastPublishTimestampInMs == 0) {
      // No funding rates published yet, use closest period starting before index price timestamp
      nextPublishTimestampInMs =
        market.lastIndexPriceTimestampInMs -
        (market.lastIndexPriceTimestampInMs % Constants.FUNDING_PERIOD_IN_MS);
    } else {
      // Previous funding rate exists, next publish timestamp is exactly one period length from previous period start
      nextPublishTimestampInMs = lastPublishTimestampInMs + Constants.FUNDING_PERIOD_IN_MS;

      if (market.lastIndexPriceTimestampInMs < nextPublishTimestampInMs) {
        // Validate index price is not stale for next period
        require(
          nextPublishTimestampInMs - market.lastIndexPriceTimestampInMs < Constants.FUNDING_PERIOD_IN_MS / 2,
          "Index price too far before next period"
        );
      } else if (nextPublishTimestampInMs + Constants.FUNDING_PERIOD_IN_MS / 2 < market.lastIndexPriceTimestampInMs) {
        // Backfill missing periods with a multiplier of 0 (no funding payments made)
        uint64 periodsToBackfill = Math.divideRoundNearest(
          market.lastIndexPriceTimestampInMs - nextPublishTimestampInMs,
          Constants.FUNDING_PERIOD_IN_MS
        );
        for (uint64 i = 0; i < periodsToBackfill; i++) {
          fundingMultipliersByBaseAssetSymbol[baseAssetSymbol].publishFundingMultipler(0);
        }
        nextPublishTimestampInMs += periodsToBackfill * Constants.FUNDING_PERIOD_IN_MS;
      }
    }

    int64 newFundingMultiplier = Math.multiplyPipsByFraction(
      int64(market.lastIndexPrice),
      // The funding rate is positive when longs pay shorts, and negative when shorts pay longs. Flipping the sign
      // on the stored multiplier allows it to be directly multiplied by a wallet's position size to determine its
      // funding credit or debit
      -1 * fundingRate,
      int64(Constants.PIP_PRICE_MULTIPLIER)
    );

    fundingMultipliersByBaseAssetSymbol[baseAssetSymbol].publishFundingMultipler(newFundingMultiplier);

    lastFundingRatePublishTimestampInMsByBaseAssetSymbol[baseAssetSymbol] = nextPublishTimestampInMs;
  }

  // solhint-disable-next-line func-name-mixedcase
  function updateWalletFundingForMarket_delegatecall(
    string memory baseAssetSymbol,
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    Market memory market = marketsByBaseAssetSymbol[baseAssetSymbol];
    require(market.exists, "Market not found");
    require(
      baseAssetSymbolsWithOpenPositionsByWallet[wallet].indexOf(market.baseAssetSymbol) != SortedStringSet.NOT_FOUND,
      "No open position in market"
    );

    Balance storage basePosition = balanceTracking.loadBalanceStructAndMigrateIfNeeded(wallet, market.baseAssetSymbol);
    (int64 funding, uint64 toTimestampInMs) = _loadWalletFundingForMarket(
      basePosition,
      true,
      market,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol
    );
    basePosition.lastUpdateTimestampInMs = toTimestampInMs;

    Balance storage quoteBalance = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      wallet,
      Constants.QUOTE_ASSET_SYMBOL
    );
    quoteBalance.balance += funding;
  }

  function backfillFundingMultipliersForMarket(
    Market memory market,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol
  ) internal {
    // Always backfill 1 period for midnight, and an additional period for every period boundary crossed since then
    uint64 periodsToBackfill = 1 + (Time.getMsSinceMidnight() / Constants.FUNDING_PERIOD_IN_MS);
    for (uint64 i = 0; i < periodsToBackfill; i++) {
      fundingMultipliersByBaseAssetSymbol[market.baseAssetSymbol].publishFundingMultipler(0);
    }

    lastFundingRatePublishTimestampInMsByBaseAssetSymbol[market.baseAssetSymbol] =
      Time.getMidnightTodayInMs() +
      // Midnight today is always the first period to be backfilled
      ((periodsToBackfill - 1) * Constants.FUNDING_PERIOD_IN_MS);
  }

  function loadOutstandingWalletFunding(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64 funding) {
    int64 marketFunding;

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      Market memory market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      Balance memory basePosition = balanceTracking.loadBalanceStructFromMigrationSourceIfNeeded(
        wallet,
        market.baseAssetSymbol
      );

      (marketFunding, ) = _loadWalletFundingForMarket(
        basePosition,
        false,
        market,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol
      );
      funding += marketFunding;
    }
  }

  function updateWalletFunding(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal {
    int64 funding;
    int64 marketFunding;
    uint64 lastFundingMultiplierTimestampInMs;

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      Market memory market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      Balance storage basePosition = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
        wallet,
        market.baseAssetSymbol
      );

      (marketFunding, lastFundingMultiplierTimestampInMs) = _loadWalletFundingForMarket(
        basePosition,
        false,
        market,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol
      );
      funding += marketFunding;
      basePosition.lastUpdateTimestampInMs = lastFundingMultiplierTimestampInMs;
    }

    Balance storage quoteBalance = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      wallet,
      Constants.QUOTE_ASSET_SYMBOL
    );
    quoteBalance.balance += funding;
  }

  function _loadWalletFundingForMarket(
    Balance memory basePosition,
    bool limitMaxTimePeriod,
    Market memory market,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol
  ) private view returns (int64, uint64) {
    // Load funding rates and index
    FundingMultiplierQuartet[] storage fundingMultipliersForMarket = fundingMultipliersByBaseAssetSymbol[
      market.baseAssetSymbol
    ];
    uint64 lastFundingRatePublishTimestampInMs = lastFundingRatePublishTimestampInMsByBaseAssetSymbol[
      market.baseAssetSymbol
    ];

    // Apply funding payments if new multipliers were published since the position was last updated
    if (basePosition.balance != 0 && basePosition.lastUpdateTimestampInMs < lastFundingRatePublishTimestampInMs) {
      // To calculate the number of multipliers to apply, start from the first funding multiplier following the last
      // position update and go up to the last published multiplier. Update timestamps are always period-aligned
      uint64 fromTimestampInMs = basePosition.lastUpdateTimestampInMs + Constants.FUNDING_PERIOD_IN_MS;

      uint64 toTimestampInMs;
      if (limitMaxTimePeriod) {
        // Limit number of multipliers applied if needed
        toTimestampInMs = Math.min(
          fromTimestampInMs + Constants.MAX_FUNDING_TIME_PERIOD_PER_UPDATE_IN_MS,
          lastFundingRatePublishTimestampInMs
        );
      } else {
        toTimestampInMs = lastFundingRatePublishTimestampInMs;
      }

      int64 aggregateFundingMultiplier = fromTimestampInMs <= toTimestampInMs
        ? fundingMultipliersForMarket.loadAggregateMultiplier(
          fromTimestampInMs,
          toTimestampInMs,
          lastFundingRatePublishTimestampInMs
        )
        : int64(0);

      int64 funding = Math.multiplyPipsByFraction(
        basePosition.balance,
        aggregateFundingMultiplier,
        int64(Constants.PIP_PRICE_MULTIPLIER)
      );

      return (funding, toTimestampInMs);
    }

    return (0, basePosition.lastUpdateTimestampInMs);
  }
}
