// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { BalanceTracking } from "./BalanceTracking.sol";
import { DeleverageType } from "./Enums.sol";
import { ExitFund } from "./ExitFund.sol";
import { Funding } from "./Funding.sol";
import { IndexPriceMargin } from "./IndexPriceMargin.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { Balance, ClosureDeleverageArguments, FundingMultiplierQuartet, Market, MarketOverrides } from "./Structs.sol";

library ClosureDeleveraging {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
  using SortedStringSet for string[];

  struct Arguments {
    ClosureDeleverageArguments externalArguments;
    DeleverageType deleverageType;
    // Exchange state
    address exitFundWallet;
    address insuranceFundWallet;
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
    require(arguments.externalArguments.deleveragingWallet != arguments.exitFundWallet, "Cannot deleverage EF");
    require(arguments.externalArguments.deleveragingWallet != arguments.insuranceFundWallet, "Cannot deleverage IF");
    if (arguments.deleverageType == DeleverageType.ExitFundClosure) {
      require(
        arguments.externalArguments.liquidatingWallet == arguments.exitFundWallet,
        "Liquidating wallet must be EF"
      );
    } else {
      // DeleverageType.InsuranceFundClosure
      require(
        arguments.externalArguments.liquidatingWallet == arguments.insuranceFundWallet,
        "Liquidating wallet must be IF"
      );
    }

    Funding.updateWalletFunding(
      arguments.externalArguments.deleveragingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.updateWalletFunding(
      arguments.externalArguments.liquidatingWallet,
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
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    if (arguments.deleverageType == DeleverageType.ExitFundClosure) {
      return
        ExitFund.getExitFundBalanceOpenedAtBlockNumber(
          arguments.exitFundWallet,
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
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    Market memory market = Validations.loadAndValidateMarket(
      arguments.externalArguments.baseAssetSymbol,
      arguments.externalArguments.liquidatingWallet,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    _validateQuoteQuantityAndDeleveragePosition(
      arguments,
      market,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateQuoteQuantityAndDeleveragePosition(
    Arguments memory arguments,
    Market memory market,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    Balance storage balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.externalArguments.liquidatingWallet,
      market.baseAssetSymbol
    );

    // Validate quote quantity
    if (arguments.deleverageType == DeleverageType.InsuranceFundClosure) {
      LiquidationValidations.validateInsuranceFundClosureQuoteQuantity(
        arguments.externalArguments.liquidationBaseQuantity,
        balanceStruct.costBasis,
        balanceStruct.balance,
        arguments.externalArguments.liquidationQuoteQuantity
      );
    } else {
      // DeleverageType.ExitFundClosure
      (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) = IndexPriceMargin
      // Use margin calculation specific to EF that accounts for its unlimited leverage
        .loadTotalAccountValueAndMaintenanceMarginRequirementForExitFund(
          arguments.externalArguments.liquidatingWallet,
          balanceTracking,
          baseAssetSymbolsWithOpenPositionsByWallet,
          marketsByBaseAssetSymbol
        );

      // The provided liquidationBaseQuantity specifies how much of the position to liquidate, so we provide this
      // quantity as the position size to validateExitFundClosureQuoteQuantity while observing the same signedness
      LiquidationValidations.validateExitFundClosureQuoteQuantity(
        balanceStruct.balance < 0
          ? (-1 * int64(arguments.externalArguments.liquidationBaseQuantity))
          : int64(arguments.externalArguments.liquidationBaseQuantity),
        market.lastIndexPrice,
        // Use market default values instead of wallet-specific overrides for the EF, since its margin fraction is zero
        market.overridableFields.maintenanceMarginFraction,
        arguments.externalArguments.liquidationQuoteQuantity,
        totalAccountValue,
        totalMaintenanceMarginRequirement
      );
    }

    balanceTracking.updatePositionForDeleverage(
      arguments.externalArguments.liquidationBaseQuantity,
      arguments.externalArguments.deleveragingWallet,
      arguments.exitFundWallet,
      arguments.externalArguments.liquidatingWallet,
      market,
      arguments.externalArguments.liquidationQuoteQuantity,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    // Validate that the deleveraged wallet still meets its initial margin requirements
    IndexPriceMargin.loadAndValidateTotalAccountValueAndInitialMarginRequirement(
      arguments.externalArguments.deleveragingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }
}
