// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { DeleverageType } from "./Enums.sol";
import { ExitFund } from "./ExitFund.sol";
import { Funding } from "./Funding.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { Math } from "./Math.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { MutatingMargin } from "./MutatingMargin.sol";
import { NonMutatingMargin } from "./NonMutatingMargin.sol";
import { String } from "./String.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { Balance, FundingMultiplierQuartet, IndexPrice, Market, MarketOverrides } from "./Structs.sol";

library ClosureDeleveraging {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
  using SortedStringSet for string[];

  struct Arguments {
    // External arguments
    DeleverageType deleverageType;
    string baseAssetSymbol;
    address deleveragingWallet;
    address liquidatingWallet;
    int64 liquidationBaseQuantity;
    int64 liquidationQuoteQuantity;
    IndexPrice[] liquidatingWalletIndexPrices; // Before liquidation
    IndexPrice[] deleveragingWalletIndexPrices; // After acquiring IF positions
    // Exchange state
    address exitFundWallet;
    address insuranceFundWallet;
    address[] indexPriceCollectionServiceWallets;
  }

  // solhint-disable-next-line func-name-mixedcase
  function deleverage_delegatecall(
    Arguments memory arguments,
    uint256 exitFundPositionOpenedAtBlockNumber,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public returns (uint256) {
    if (arguments.deleverageType == DeleverageType.InsuranceFundClosure) {
      require(arguments.liquidatingWallet != arguments.exitFundWallet, "Cannot liquidate EF");
    } else {
      // DeleverageType.ExitFundClosure
      require(arguments.liquidatingWallet != arguments.insuranceFundWallet, "Cannot liquidate IF");
    }
    require(arguments.deleveragingWallet != arguments.exitFundWallet, "Cannot deleverage EF");
    require(arguments.deleveragingWallet != arguments.insuranceFundWallet, "Cannot deleverage IF");

    Funding.updateWalletFunding(
      arguments.deleveragingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.updateWalletFunding(
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
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
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
    market = marketsByBaseAssetSymbol[arguments.baseAssetSymbol];
    require(market.exists && market.isActive, "No active market found");

    uint256 i = baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet].indexOf(
      arguments.baseAssetSymbol
    );
    require(i != SortedStringSet.NOT_FOUND, "Index price not found for market");

    indexPrice = arguments.liquidatingWalletIndexPrices[i];
  }

  function _validateQuoteQuantityAndDeleveragePosition(
    Arguments memory arguments,
    Market memory market,
    IndexPrice memory indexPrice,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    Balance storage balance = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.liquidatingWallet,
      market.baseAssetSymbol
    );
    Validations.validateIndexPrice(indexPrice, arguments.indexPriceCollectionServiceWallets, market);

    if (arguments.deleverageType == DeleverageType.InsuranceFundClosure) {
      LiquidationValidations.validateInsuranceFundClosureQuoteQuantity(
        arguments.liquidationBaseQuantity,
        balance.costBasis,
        balance.balance,
        arguments.liquidationQuoteQuantity
      );
    } else {
      // DeleverageType.ExitFundClosure
      int64 totalAccountValue = NonMutatingMargin.loadTotalAccountValue(
        NonMutatingMargin.LoadArguments(
          arguments.liquidatingWallet,
          arguments.liquidatingWalletIndexPrices,
          arguments.indexPriceCollectionServiceWallets
        ),
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      );

      LiquidationValidations.validateExitFundClosureQuoteQuantity(
        arguments.liquidationBaseQuantity,
        indexPrice.price,
        arguments.liquidationQuoteQuantity,
        totalAccountValue
      );
    }

    balanceTracking.updatePositionForDeleverage(
      arguments.liquidationBaseQuantity,
      arguments.deleveragingWallet,
      arguments.liquidatingWallet,
      market,
      arguments.liquidationQuoteQuantity,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    // Validate that the deleveraged wallet still meets its initial margin requirements
    MutatingMargin.loadAndValidateTotalAccountValueAndInitialMarginRequirementAndUpdateLastIndexPrice(
      NonMutatingMargin.LoadArguments(
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
