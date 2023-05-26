// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Funding } from "./Funding.sol";
import { IndexPriceMargin } from "./IndexPriceMargin.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Math } from "./Math.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { AcquisitionDeleverageArguments, Balance, FundingMultiplierQuartet, Market, MarketOverrides } from "./Structs.sol";

library WalletInMaintenanceAcquisitionDeleveraging {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
  using SortedStringSet for string[];

  // solhint-disable-next-line func-name-mixedcase
  function deleverage_delegatecall(
    AcquisitionDeleverageArguments memory arguments,
    address exitFundWallet,
    address insuranceFundWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    require(arguments.liquidatingWallet != arguments.counterpartyWallet, "Cannot liquidate wallet against itself");
    require(arguments.liquidatingWallet != exitFundWallet, "Cannot liquidate EF");
    require(arguments.liquidatingWallet != insuranceFundWallet, "Cannot liquidate IF");
    require(arguments.counterpartyWallet != exitFundWallet, "Cannot deleverage EF");
    require(arguments.counterpartyWallet != insuranceFundWallet, "Cannot deleverage IF");

    Funding.applyOutstandingWalletFunding(
      arguments.counterpartyWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    Funding.applyOutstandingWalletFunding(
      arguments.liquidatingWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    int64 insuranceFundWalletOutstandingFundingPayment = Funding.loadOutstandingWalletFunding(
      insuranceFundWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    _validateArgumentsAndDeleverage(
      arguments,
      exitFundWallet,
      insuranceFundWallet,
      insuranceFundWalletOutstandingFundingPayment,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateArgumentsAndDeleverage(
    AcquisitionDeleverageArguments memory arguments,
    address exitFundWallet,
    address insuranceFundWallet,
    int64 insuranceFundWalletOutstandingFundingPayment,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    require(
      baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet].indexOf(arguments.baseAssetSymbol) !=
        SortedStringSet.NOT_FOUND,
      "No open position in market"
    );

    // Validate that the liquidating account has fallen below margin requirements
    (
      int256 liquidatingWalletTotalAccountValueInDoublePips,
      uint256 liquidatingWalletTotalMaintenanceMarginRequirementInTriplePips
    ) = IndexPriceMargin.loadTotalAccountValueInDoublePipsAndMaintenanceMarginRequirementInTriplePips(
        arguments.liquidatingWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    require(
      Math.doublePipsToPips(liquidatingWalletTotalAccountValueInDoublePips) <
        Math.toInt64(Math.triplePipsToPips(liquidatingWalletTotalMaintenanceMarginRequirementInTriplePips)),
      "Maintenance margin requirement met"
    );

    // Do not proceed with deleverage if the Insurance Fund can acquire the wallet's positions
    _validateInsuranceFundCannotLiquidateWallet(
      arguments,
      insuranceFundWallet,
      insuranceFundWalletOutstandingFundingPayment,
      liquidatingWalletTotalAccountValueInDoublePips,
      liquidatingWalletTotalMaintenanceMarginRequirementInTriplePips,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    // Liquidate specified position by deleveraging a counterparty position
    _validateDeleverageQuoteQuantityAndUpdatePositions(
      arguments,
      exitFundWallet,
      liquidatingWalletTotalAccountValueInDoublePips,
      liquidatingWalletTotalMaintenanceMarginRequirementInTriplePips,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _updatePositionsForDeleverage(
    AcquisitionDeleverageArguments memory arguments,
    address exitFundWallet,
    Market memory market,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    balanceTracking.updatePositionsForDeleverage(
      arguments.liquidationBaseQuantity,
      arguments.counterpartyWallet,
      exitFundWallet,
      arguments.liquidatingWallet,
      market,
      arguments.liquidationQuoteQuantity,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    // Validate that the deleveraged wallet still meets its initial margin requirements
    IndexPriceMargin.validateInitialMarginRequirement(
      arguments.counterpartyWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateDeleverageQuoteQuantity(
    AcquisitionDeleverageArguments memory arguments,
    int256 totalAccountValueInDoublePips,
    uint256 totalMaintenanceMarginRequirementInTriplePips,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private returns (Market memory market) {
    market = Validations.loadAndValidateActiveMarket(
      arguments.baseAssetSymbol,
      arguments.liquidatingWallet,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    Balance memory balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.liquidatingWallet,
      market.baseAssetSymbol
    );

    LiquidationValidations.validateQuoteQuantityAtBankruptcyPrice(
      market.lastIndexPrice,
      balanceStruct.balance < 0
        ? (-1 * Math.toInt64(arguments.liquidationBaseQuantity))
        : Math.toInt64(arguments.liquidationBaseQuantity),
      arguments.liquidationQuoteQuantity,
      market
        .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
        .overridableFields
        .maintenanceMarginFraction,
      totalAccountValueInDoublePips,
      totalMaintenanceMarginRequirementInTriplePips
    );
  }

  function _validateDeleverageQuoteQuantityAndUpdatePositions(
    AcquisitionDeleverageArguments memory arguments,
    address exitFundWallet,
    int256 totalAccountValueInDoublePips,
    uint256 totalMaintenanceMarginRequirementInTriplePips,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    Market memory market = _validateDeleverageQuoteQuantity(
      arguments,
      totalAccountValueInDoublePips,
      totalMaintenanceMarginRequirementInTriplePips,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    _updatePositionsForDeleverage(
      arguments,
      exitFundWallet,
      market,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateInsuranceFundCannotLiquidateWallet(
    AcquisitionDeleverageArguments memory arguments,
    address insuranceFundWallet,
    int64 insuranceFundWalletOutstandingFundingPayment,
    int256 liquidatingWalletTotalAccountValueInDoublePips,
    uint256 liquidatingWalletTotalMaintenanceMarginRequirementInTriplePips,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    // Build array of union of open position base asset symbols for both liquidating and IF wallets. Result of merge
    // will already be de-duped and sorted
    string[] memory baseAssetSymbolsForInsuranceFundAndLiquidatingWallet = baseAssetSymbolsWithOpenPositionsByWallet[
      insuranceFundWallet
    ].merge(baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet]);

    // Allocate struct to hold arguments needed to perform validation against IF liquidation of wallet
    IndexPriceMargin.ValidateInsuranceFundCannotLiquidateWalletArguments memory loadArguments = IndexPriceMargin
      .ValidateInsuranceFundCannotLiquidateWalletArguments(
        insuranceFundWallet,
        insuranceFundWalletOutstandingFundingPayment,
        arguments.liquidatingWallet,
        arguments.validateInsuranceFundCannotLiquidateWalletQuoteQuantities,
        new Market[](baseAssetSymbolsForInsuranceFundAndLiquidatingWallet.length)
      );

    // Loop through open position union and populate argument struct fields
    for (uint8 i = 0; i < baseAssetSymbolsForInsuranceFundAndLiquidatingWallet.length; i++) {
      // Load market
      loadArguments.markets[i] = marketsByBaseAssetSymbol[baseAssetSymbolsForInsuranceFundAndLiquidatingWallet[i]];

      _validateInsuranceFundLiquidationQuoteQuantityForPosition(
        arguments,
        baseAssetSymbolsForInsuranceFundAndLiquidatingWallet,
        i,
        liquidatingWalletTotalAccountValueInDoublePips,
        liquidatingWalletTotalMaintenanceMarginRequirementInTriplePips,
        loadArguments,
        balanceTracking,
        marketOverridesByBaseAssetSymbolAndWallet
      );
    }

    // Argument struct is populated with validated field values, pass through to margin validation
    IndexPriceMargin.validateInsuranceFundCannotLiquidateWallet(
      loadArguments,
      balanceTracking,
      marketOverridesByBaseAssetSymbolAndWallet
    );
  }

  function _validateInsuranceFundLiquidationQuoteQuantityForPosition(
    AcquisitionDeleverageArguments memory arguments,
    string[] memory baseAssetSymbolsForInsuranceFundAndLiquidatingWallet,
    uint8 index,
    int256 liquidatingWalletTotalAccountValueInDoublePips,
    uint256 liquidatingWalletTotalMaintenanceMarginRequirementInTriplePips,
    IndexPriceMargin.ValidateInsuranceFundCannotLiquidateWalletArguments memory loadArguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) private {
    int64 positionSize = balanceTracking.loadBalanceAndMigrateIfNeeded(
      arguments.liquidatingWallet,
      baseAssetSymbolsForInsuranceFundAndLiquidatingWallet[index]
    );

    if (positionSize != 0) {
      LiquidationValidations.validateQuoteQuantityAtBankruptcyPrice(
        loadArguments.markets[index].lastIndexPrice,
        positionSize,
        arguments.validateInsuranceFundCannotLiquidateWalletQuoteQuantities[index],
        loadArguments
          .markets[index]
          .loadMarketWithOverridesForWallet(arguments.liquidatingWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maintenanceMarginFraction,
        liquidatingWalletTotalAccountValueInDoublePips,
        liquidatingWalletTotalMaintenanceMarginRequirementInTriplePips
      );
    } else {
      require(
        arguments.validateInsuranceFundCannotLiquidateWalletQuoteQuantities[index] == 0,
        "Invalid quote quantity"
      );
    }
  }
}
