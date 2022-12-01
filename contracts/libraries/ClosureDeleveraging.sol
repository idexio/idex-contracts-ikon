// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { DeleverageType } from "./Enums.sol";
import { ExitFund } from "./ExitFund.sol";
import { Funding } from "./Funding.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { Margin } from "./Margin.sol";
import { Math } from "./Math.sol";
import { MarketOverrides } from "./MarketOverrides.sol";
import { String } from "./String.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { Balance, FundingMultiplierQuartet, Market, IndexPrice } from "./Structs.sol";

library ClosureDeleveraging {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketOverrides for Market;
  using SortedStringSet for string[];

  struct Arguments {
    // External arguments
    DeleverageType deleverageType;
    string baseAssetSymbol;
    address deleveragingWallet;
    address liquidatingWallet;
    int64 liquidationBaseQuantityInPips;
    int64 liquidationQuoteQuantityInPips;
    IndexPrice[] liquidatingWalletIndexPrices; // Before liquidation
    IndexPrice[] deleveragingWalletIndexPrices; // After acquiring IF positions
    // Exchange state
    address[] indexPriceCollectionServiceWallets;
  }

  function deleverage(
    Arguments memory arguments,
    uint256 exitFundPositionOpenedAtBlockNumber,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public returns (uint256) {
    Funding.updateWalletFundingInternal(
      arguments.deleveragingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.updateWalletFundingInternal(
      arguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    _validateArgumentsAndDeleverage(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    if (arguments.deleverageType == DeleverageType.ExitFundClosure) {
      return
        ExitFund.getExitFundBalanceOpenedAtBlockNumber(
          arguments.liquidatingWallet,
          exitFundPositionOpenedAtBlockNumber,
          balanceTracking,
          baseAssetSymbolsWithOpenPositionsByWallet
        );
    }

    return exitFundPositionOpenedAtBlockNumber;
  }

  function _validateArgumentsAndDeleverage(
    Arguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    (Market memory market, IndexPrice memory indexPrice) = _loadMarketAndIndexPrice(
      arguments,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    _validateQuoteQuantityAndDeleveragePosition(
      arguments,
      market,
      indexPrice,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _loadMarketAndIndexPrice(
    Arguments memory arguments,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (Market memory market, IndexPrice memory indexPrice) {
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      if (String.isEqual(baseAssetSymbols[i], arguments.baseAssetSymbol)) {
        market = marketsByBaseAssetSymbol[arguments.baseAssetSymbol];
        indexPrice = arguments.liquidatingWalletIndexPrices[i];
      }
    }

    require(market.exists && market.isActive, "No active market found");
  }

  function _validateQuoteQuantityAndDeleveragePosition(
    Arguments memory arguments,
    Market memory market,
    IndexPrice memory indexPrice,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    Balance storage balance = balanceTracking.loadBalanceAndMigrateIfNeeded(
      arguments.liquidatingWallet,
      market.baseAssetSymbol
    );
    Validations.validateIndexPrice(indexPrice, market, arguments.indexPriceCollectionServiceWallets);

    if (arguments.deleverageType == DeleverageType.InsuranceFundClosure) {
      LiquidationValidations.validateInsuranceFundClosureQuoteQuantity(
        arguments.liquidationBaseQuantityInPips,
        balance.costBasisInPips,
        balance.balanceInPips,
        arguments.liquidationQuoteQuantityInPips
      );
    } else {
      // DeleverageType.ExitFundClosure
      int64 totalAccountValueInPips = Margin.loadTotalAccountValue(
        Margin.LoadArguments(
          arguments.liquidatingWallet,
          arguments.liquidatingWalletIndexPrices,
          arguments.indexPriceCollectionServiceWallets
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      );

      LiquidationValidations.validateExitFundClosureQuoteQuantity(
        arguments.liquidationBaseQuantityInPips,
        indexPrice.price,
        arguments.liquidationQuoteQuantityInPips,
        totalAccountValueInPips
      );
    }

    balanceTracking.updatePositionForDeleverage(
      arguments.liquidationBaseQuantityInPips,
      arguments.deleveragingWallet,
      arguments.liquidatingWallet,
      market,
      arguments.liquidationQuoteQuantityInPips,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    // Validate that the deleveraged wallet still meets its initial margin requirements
    // TODO Should this be maintenance margin?
    Margin.loadAndValidateTotalAccountValueAndInitialMarginRequirement(
      Margin.LoadArguments(
        arguments.deleveragingWallet,
        arguments.deleveragingWalletIndexPrices,
        arguments.indexPriceCollectionServiceWallets
      ),
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }
}
