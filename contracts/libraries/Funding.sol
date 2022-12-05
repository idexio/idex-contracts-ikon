// SPDX-License-Identifier: LGPL-3.0-only

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { FundingMultipliers } from "./FundingMultipliers.sol";
import { Math } from "./Math.sol";
import { NonMutatingMargin } from "./NonMutatingMargin.sol";
import { Validations } from "./Validations.sol";
import { Balance, FundingMultiplierQuartet, Market, IndexPrice } from "./Structs.sol";

pragma solidity 0.8.17;

library Funding {
  using BalanceTracking for BalanceTracking.Storage;
  using FundingMultipliers for FundingMultiplierQuartet[];

  function loadOutstandingWalletFunding(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (int64 funding) {
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
    NonMutatingMargin.LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (int64) {
    return
      NonMutatingMargin.loadTotalAccountValueInternal(
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

  function publishFundingMutipliers(
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
      require(
        lastPublishTimestampInMs > 0
          ? lastPublishTimestampInMs + Constants.FUNDING_PERIOD_IN_MS == indexPrice.timestampInMs
          : indexPrice.timestampInMs % Constants.FUNDING_PERIOD_IN_MS == 0,
        "Input price not period aligned"
      );

      int64 newFundingMultiplier = Math.multiplyPipsByFraction(
        int64(indexPrice.price),
        fundingRate,
        int64(Constants.PIP_PRICE_MULTIPLIER)
      );

      fundingMultipliersByBaseAssetSymbol[indexPrice.baseAssetSymbol].publishFundingMultipler(newFundingMultiplier);

      lastFundingRatePublishTimestampInMsByBaseAssetSymbol[indexPrice.baseAssetSymbol] = indexPrice.timestampInMs;
    }
  }

  function updateWalletFunding(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    updateWalletFundingInternal(
      wallet,
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

  function updateWalletFundingInternal(
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
