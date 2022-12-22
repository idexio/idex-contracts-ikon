// SPDX-License-Identifier: LGPL-3.0-only

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { FundingMultiplierQuartetHelper } from "./FundingMultiplierQuartetHelper.sol";
import { Math } from "./Math.sol";
import { NonMutatingMargin } from "./NonMutatingMargin.sol";
import { OnChainPriceFeedMargin } from "./OnChainPriceFeedMargin.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { Balance, FundingMultiplierQuartet, Market, IndexPrice } from "./Structs.sol";

pragma solidity 0.8.17;

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
  function loadTotalAccountValueIncludingOutstandingWalletFunding_delegatecall(
    NonMutatingMargin.LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (int64) {
    int64 totalAccountValue = arguments.indexPrices.length == 0
      ? OnChainPriceFeedMargin.loadTotalAccountValue(
        arguments.wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      )
      : NonMutatingMargin.loadTotalAccountValue(
        arguments,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      );

    return
      totalAccountValue +
      loadOutstandingWalletFunding(
        arguments.wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsByBaseAssetSymbol
      );
  }

  // solhint-disable-next-line func-name-mixedcase
  function publishFundingMutiplier_delegatecall(
    int64 fundingRate,
    IndexPrice memory indexPrice,
    address[] memory indexPriceCollectionServiceWallets,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    Validations.validateIndexPriceSignature(indexPrice, indexPriceCollectionServiceWallets);

    Market memory market = marketsByBaseAssetSymbol[indexPrice.baseAssetSymbol];
    require(market.exists && market.isActive, "No active market found");

    uint64 lastPublishTimestampInMs = lastFundingRatePublishTimestampInMsByBaseAssetSymbol[indexPrice.baseAssetSymbol];

    uint64 nextPublishTimestampInMs;
    if (lastPublishTimestampInMs == 0) {
      // No funding rates published yet, use closest period starting before index price timestamp
      nextPublishTimestampInMs = indexPrice.timestampInMs - (indexPrice.timestampInMs % Constants.FUNDING_PERIOD_IN_MS);
    } else {
      // Previous funding rate exists, next publish timestamp is exactly one period length from previous period start
      nextPublishTimestampInMs = lastPublishTimestampInMs + Constants.FUNDING_PERIOD_IN_MS;

      if (indexPrice.timestampInMs < nextPublishTimestampInMs) {
        // Validate index price is not stale for next period
        require(
          nextPublishTimestampInMs - indexPrice.timestampInMs < Constants.FUNDING_PERIOD_IN_MS / 2,
          "Index price too far before next period"
        );
      } else if (nextPublishTimestampInMs + Constants.FUNDING_PERIOD_IN_MS / 2 < indexPrice.timestampInMs) {
        // Backfill missing periods with a multiplier of 0 (no funding payments made)
        uint64 periodsToBackfill = Math.divideRoundNearest(
          indexPrice.timestampInMs - nextPublishTimestampInMs,
          Constants.FUNDING_PERIOD_IN_MS
        );
        for (uint64 j = 0; j < periodsToBackfill; j++) {
          fundingMultipliersByBaseAssetSymbol[indexPrice.baseAssetSymbol].publishFundingMultipler(0);
        }
        nextPublishTimestampInMs += periodsToBackfill * Constants.FUNDING_PERIOD_IN_MS;
      }
    }

    int64 newFundingMultiplier = Math.multiplyPipsByFraction(
      int64(indexPrice.price),
      // The funding rate is positive when longs pay shorts, and negative when shorts pay longs. Flipping the sign
      // on the stored multiplier allows it to be directly multiplied by a wallet's position size to determine its
      // funding credit or debit
      -1 * fundingRate,
      int64(Constants.PIP_PRICE_MULTIPLIER)
    );

    fundingMultipliersByBaseAssetSymbol[indexPrice.baseAssetSymbol].publishFundingMultipler(newFundingMultiplier);

    lastFundingRatePublishTimestampInMsByBaseAssetSymbol[indexPrice.baseAssetSymbol] = nextPublishTimestampInMs;
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
    for (uint8 marketIndex = 0; marketIndex < baseAssetSymbols.length; marketIndex++) {
      Market memory market = marketsByBaseAssetSymbol[baseAssetSymbols[marketIndex]];
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
    for (uint8 marketIndex = 0; marketIndex < baseAssetSymbols.length; marketIndex++) {
      Market memory market = marketsByBaseAssetSymbol[baseAssetSymbols[marketIndex]];
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
      // position update and go up to the last published multiplier
      uint64 fromTimestampInMs = basePosition.lastUpdateTimestampInMs +
        Constants.FUNDING_PERIOD_IN_MS -
        (basePosition.lastUpdateTimestampInMs % Constants.FUNDING_PERIOD_IN_MS);

      uint64 toTimestampInMs;
      if (limitMaxTimePeriod) {
        toTimestampInMs = Math.min(
          fromTimestampInMs + Constants.MAX_FUNDING_TIME_PERIOD_PER_UPDATE_IN_MS,
          lastFundingRatePublishTimestampInMs
        );
      } else {
        toTimestampInMs = lastFundingRatePublishTimestampInMs;
      }

      int64 aggregateFundingMultiplier = fundingMultipliersForMarket.loadAggregateMultiplier(
        fromTimestampInMs,
        toTimestampInMs,
        lastFundingRatePublishTimestampInMs
      );

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
