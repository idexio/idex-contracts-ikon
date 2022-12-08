// SPDX-License-Identifier: LGPL-3.0-only

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { FundingMultipliers } from "./FundingMultipliers.sol";
import { Math } from "./Math.sol";
import { NonMutatingMargin } from "./NonMutatingMargin.sol";
import { OnChainPriceFeedMargin } from "./OnChainPriceFeedMargin.sol";
import { Validations } from "./Validations.sol";
import { Balance, FundingMultiplierQuartet, Market, IndexPrice } from "./Structs.sol";

pragma solidity 0.8.17;

library Funding {
  using BalanceTracking for BalanceTracking.Storage;
  using FundingMultipliers for FundingMultiplierQuartet[];

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
  function publishFundingMutipliers_delegatecall(
    int64[] memory fundingRates,
    IndexPrice[] memory indexPrices,
    address[] memory indexPriceCollectionServiceWallets,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol
  ) public {
    for (uint8 i = 0; i < indexPrices.length; i++) {
      (IndexPrice memory indexPrice, int64 fundingRate) = (indexPrices[i], fundingRates[i]);
      Validations.validateIndexPriceSignature(indexPrice, indexPriceCollectionServiceWallets);

      uint64 lastPublishTimestampInMs = lastFundingRatePublishTimestampInMsByBaseAssetSymbol[
        indexPrice.baseAssetSymbol
      ];

      uint64 nextPublishTimestampInMs;
      if (lastPublishTimestampInMs == 0) {
        // No funding rates published yet, use closest period starting before index price timestamp
        nextPublishTimestampInMs =
          indexPrice.timestampInMs -
          (indexPrice.timestampInMs % Constants.FUNDING_PERIOD_IN_MS);
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
        fundingRate,
        int64(Constants.PIP_PRICE_MULTIPLIER)
      );

      fundingMultipliersByBaseAssetSymbol[indexPrice.baseAssetSymbol].publishFundingMultipler(newFundingMultiplier);

      lastFundingRatePublishTimestampInMsByBaseAssetSymbol[indexPrice.baseAssetSymbol] = nextPublishTimestampInMs;
    }
  }

  // solhint-disable-next-line func-name-mixedcase
  function updateWalletFunding_delegatecall(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    updateWalletFunding(
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
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

      (marketFunding, ) = loadWalletFundingForMarket(
        basePosition,
        market,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol
      );
      funding += marketFunding;
    }
  }

  function loadWalletFundingForMarket(
    Balance memory basePosition,
    Market memory market,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol
  ) internal view returns (int64 funding, uint64 lastFundingMultiplierTimestampInMs) {
    // Load funding rates and index
    FundingMultiplierQuartet[] storage fundingMultipliersForMarket = fundingMultipliersByBaseAssetSymbol[
      market.baseAssetSymbol
    ];
    lastFundingMultiplierTimestampInMs = lastFundingRatePublishTimestampInMsByBaseAssetSymbol[market.baseAssetSymbol];

    // Apply hourly funding payments if new rates were published since this balance was last updated
    if (basePosition.balance != 0 && basePosition.lastUpdateTimestampInMs < lastFundingMultiplierTimestampInMs) {
      int64 aggregateFundingMultiplier = fundingMultipliersForMarket.loadAggregateMultiplier(
        basePosition.lastUpdateTimestampInMs,
        lastFundingMultiplierTimestampInMs
      );

      funding += Math.multiplyPipsByFraction(
        basePosition.balance,
        aggregateFundingMultiplier,
        int64(Constants.PIP_PRICE_MULTIPLIER)
      );
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

      (marketFunding, lastFundingMultiplierTimestampInMs) = loadWalletFundingForMarket(
        basePosition,
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
}
