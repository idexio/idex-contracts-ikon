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

  // solhint-disable-next-line func-name-mixedcase
  function deleverage_delegatecall(
    ClosureDeleverageArguments memory arguments,
    DeleverageType deleverageType,
    uint256 exitFundPositionOpenedAtBlockNumber,
    address exitFundWallet,
    address insuranceFundWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public returns (uint256) {
    require(arguments.deleveragingWallet != exitFundWallet, "Cannot deleverage EF");
    require(arguments.deleveragingWallet != insuranceFundWallet, "Cannot deleverage IF");
    if (deleverageType == DeleverageType.ExitFundClosure) {
      require(arguments.liquidatingWallet == exitFundWallet, "Liquidating wallet must be EF");
    } else {
      // DeleverageType.InsuranceFundClosure
      require(arguments.liquidatingWallet == insuranceFundWallet, "Liquidating wallet must be IF");
    }

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
      deleverageType,
      exitFundWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    if (deleverageType == DeleverageType.ExitFundClosure) {
      return
        ExitFund.getExitFundBalanceOpenedAtBlockNumber(
          exitFundPositionOpenedAtBlockNumber,
          exitFundWallet,
          balanceTracking,
          baseAssetSymbolsWithOpenPositionsByWallet
        );
    }

    return exitFundPositionOpenedAtBlockNumber;
  }

  function _validateArgumentsAndDeleverage(
    ClosureDeleverageArguments memory arguments,
    DeleverageType deleverageType,
    address exitFundWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    Market memory market = Validations.loadAndValidateActiveMarket(
      arguments.baseAssetSymbol,
      arguments.liquidatingWallet,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    _validateQuoteQuantityAndDeleveragePosition(
      arguments,
      deleverageType,
      exitFundWallet,
      market,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateQuoteQuantityAndDeleveragePosition(
    ClosureDeleverageArguments memory arguments,
    DeleverageType deleverageType,
    address exitFundWallet,
    Market memory market,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    Balance storage balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.liquidatingWallet,
      market.baseAssetSymbol
    );

    // Validate quote quantity
    if (deleverageType == DeleverageType.InsuranceFundClosure) {
      LiquidationValidations.validateInsuranceFundClosureQuoteQuantity(
        arguments.liquidationBaseQuantity,
        balanceStruct.costBasis,
        balanceStruct.balance,
        arguments.liquidationQuoteQuantity
      );
    } else {
      // DeleverageType.ExitFundClosure
      (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) = IndexPriceMargin
      // Use margin calculation specific to EF that accounts for its unlimited leverage
        .loadTotalAccountValueAndMaintenanceMarginRequirementForExitFund(
          arguments.liquidatingWallet,
          balanceTracking,
          baseAssetSymbolsWithOpenPositionsByWallet,
          marketsByBaseAssetSymbol
        );

      // The provided liquidationBaseQuantity specifies how much of the position to liquidate, so we provide this
      // quantity as the position size to validateExitFundClosureQuoteQuantity while observing the same signedness
      LiquidationValidations.validateExitFundClosureQuoteQuantity(
        balanceStruct.balance < 0
          ? (-1 * int64(arguments.liquidationBaseQuantity))
          : int64(arguments.liquidationBaseQuantity),
        market.lastIndexPrice,
        // Use market default values instead of wallet-specific overrides for the EF, since its margin fraction is zero
        market.overridableFields.maintenanceMarginFraction,
        arguments.liquidationQuoteQuantity,
        totalAccountValue,
        totalMaintenanceMarginRequirement
      );
    }

    balanceTracking.updatePositionsForDeleverage(
      arguments.liquidationBaseQuantity,
      arguments.deleveragingWallet,
      exitFundWallet,
      arguments.liquidatingWallet,
      market,
      arguments.liquidationQuoteQuantity,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    // Validate that the deleveraged wallet still meets its initial margin requirements
    IndexPriceMargin.loadAndValidateTotalAccountValueAndInitialMarginRequirement(
      arguments.deleveragingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }
}
