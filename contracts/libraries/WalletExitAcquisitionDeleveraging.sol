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
import { AcquisitionDeleverageArguments, Balance, FundingMultiplierQuartet, Market, MarketOverrides, WalletExit } from "./Structs.sol";
import { WalletExitAcquisitionDeleveragePriceStrategy } from "./Enums.sol";

library WalletExitAcquisitionDeleveraging {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
  using SortedStringSet for string[];

  struct ValidateDeleverageQuoteQuantityArguments {
    AcquisitionDeleverageArguments acquisitionDeleverageArguments;
    WalletExitAcquisitionDeleveragePriceStrategy deleveragePriceStrategy;
    address exitFundWallet;
    int256 liquidatingWalletTotalAccountValueInDoublePips;
    uint256 liquidatingWalletTotalMaintenanceMarginRequirementInTriplePips;
  }

  struct ValidateExitQuoteQuantityArguments {
    WalletExitAcquisitionDeleveragePriceStrategy deleveragePriceStrategy;
    uint64 indexPrice;
    int64 liquidationBaseQuantity;
    uint64 liquidationQuoteQuantity;
    uint64 maintenanceMarginFraction;
    int256 liquidatingWalletTotalAccountValueInDoublePips;
    uint256 liquidatingWalletTotalMaintenanceMarginRequirementInTriplePips;
  }

  /**
   * @notice Emitted when the Dispatcher Wallet submits an exited wallet position deleverage with
   * `deleverageExitAcquisition`
   */
  event DeleveragedExitAcquisition(
    string baseAssetSymbol,
    address counterpartyWallet,
    address liquidatingWallet,
    uint64 liquidationBaseQuantity,
    uint64 liquidationQuoteQuantity
  );

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
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => WalletExit) storage walletExits
  ) public {
    require(arguments.liquidatingWallet != arguments.counterpartyWallet, "Cannot liquidate wallet against itself");
    // The EF and IF cannot be exited, so no need validate that they are not set as liquidating wallet
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

    _validateArgumentsAndDeleverage(
      arguments,
      exitFundWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol,
      walletExits
    );

    emit DeleveragedExitAcquisition(
      arguments.baseAssetSymbol,
      arguments.counterpartyWallet,
      arguments.liquidatingWallet,
      arguments.liquidationBaseQuantity,
      arguments.liquidationQuoteQuantity
    );
  }

  function _determineAndStoreDeleveragePriceStrategy(
    int64 exitAccountValue,
    address wallet,
    mapping(address => WalletExit) storage walletExits
  ) private returns (WalletExitAcquisitionDeleveragePriceStrategy) {
    WalletExit storage walletExit = walletExits[wallet];

    // Once we select bankruptcy price use it for the remainder of exit deleveraging
    if (walletExit.deleveragePriceStrategy == WalletExitAcquisitionDeleveragePriceStrategy.BankruptcyPrice) {
      return WalletExitAcquisitionDeleveragePriceStrategy.BankruptcyPrice;
    }

    // Wallets with a positive total account value should use the exit price (worse of entry price or current index
    // price) unless a change in index pricing between deleveraging the wallet positions moves its exit account value
    // negative, at which point the bankruptcy price will be used for the remainder of the positions
    walletExit.deleveragePriceStrategy = exitAccountValue <= 0
      ? WalletExitAcquisitionDeleveragePriceStrategy.BankruptcyPrice
      : WalletExitAcquisitionDeleveragePriceStrategy.ExitPrice;

    return walletExit.deleveragePriceStrategy;
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

    // Validate that the counterparty wallet still meets its maintenance margin requirements
    IndexPriceMargin.validateMaintenanceMarginRequirement(
      arguments.counterpartyWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateArgumentsAndDeleverage(
    AcquisitionDeleverageArguments memory arguments,
    address exitFundWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => WalletExit) storage walletExits
  ) private {
    require(
      baseAssetSymbolsWithOpenPositionsByWallet[arguments.liquidatingWallet].indexOf(arguments.baseAssetSymbol) !=
        SortedStringSet.NOT_FOUND,
      "No open position in market"
    );

    (
      int64 exitAccountValue,
      int256 liquidatingWalletTotalAccountValueInDoublePips,
      uint256 liquidatingWalletTotalMaintenanceMarginRequirementInTriplePips
    ) = IndexPriceMargin
        .loadTotalExitAccountValueAndAccountValueInDoublePipsAndMaintenanceMarginRequirementInTriplePips(
          arguments.liquidatingWallet,
          balanceTracking,
          baseAssetSymbolsWithOpenPositionsByWallet,
          marketOverridesByBaseAssetSymbolAndWallet,
          marketsByBaseAssetSymbol
        );

    // Determine price strategy to use for subsequent IF acquisition simulation and actual position deleverage
    WalletExitAcquisitionDeleveragePriceStrategy deleveragePriceStrategy = _determineAndStoreDeleveragePriceStrategy(
      exitAccountValue,
      arguments.liquidatingWallet,
      walletExits
    );

    ValidateDeleverageQuoteQuantityArguments memory validateDeleverageQuoteQuantityArguments;
    validateDeleverageQuoteQuantityArguments.acquisitionDeleverageArguments = arguments;
    validateDeleverageQuoteQuantityArguments.deleveragePriceStrategy = deleveragePriceStrategy;
    validateDeleverageQuoteQuantityArguments.exitFundWallet = exitFundWallet;
    validateDeleverageQuoteQuantityArguments
      .liquidatingWalletTotalAccountValueInDoublePips = liquidatingWalletTotalAccountValueInDoublePips;
    validateDeleverageQuoteQuantityArguments
      .liquidatingWalletTotalMaintenanceMarginRequirementInTriplePips = liquidatingWalletTotalMaintenanceMarginRequirementInTriplePips;

    // Liquidate specified position by deleveraging a counterparty position
    _validateDeleverageQuoteQuantityAndUpdatePositions(
      validateDeleverageQuoteQuantityArguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateDeleverageQuoteQuantity(
    ValidateDeleverageQuoteQuantityArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private returns (Market memory market) {
    market = Validations.loadAndValidateActiveMarket(
      arguments.acquisitionDeleverageArguments.baseAssetSymbol,
      arguments.acquisitionDeleverageArguments.liquidatingWallet,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    Balance memory balanceStruct = balanceTracking.loadBalanceStructAndMigrateIfNeeded(
      arguments.acquisitionDeleverageArguments.liquidatingWallet,
      market.baseAssetSymbol
    );

    ValidateExitQuoteQuantityArguments memory validateExitQuoteQuantityArguments;
    validateExitQuoteQuantityArguments.deleveragePriceStrategy = arguments.deleveragePriceStrategy;
    validateExitQuoteQuantityArguments.indexPrice = market.lastIndexPrice;
    validateExitQuoteQuantityArguments.liquidationBaseQuantity = balanceStruct.balance < 0
      ? (-1 * Math.toInt64(arguments.acquisitionDeleverageArguments.liquidationBaseQuantity))
      : Math.toInt64(arguments.acquisitionDeleverageArguments.liquidationBaseQuantity);
    validateExitQuoteQuantityArguments.liquidationQuoteQuantity = arguments
      .acquisitionDeleverageArguments
      .liquidationQuoteQuantity;
    validateExitQuoteQuantityArguments.maintenanceMarginFraction = market
      .loadMarketWithOverridesForWallet(
        arguments.acquisitionDeleverageArguments.liquidatingWallet,
        marketOverridesByBaseAssetSymbolAndWallet
      )
      .overridableFields
      .maintenanceMarginFraction;
    validateExitQuoteQuantityArguments.liquidatingWalletTotalAccountValueInDoublePips = arguments
      .liquidatingWalletTotalAccountValueInDoublePips;
    validateExitQuoteQuantityArguments.liquidatingWalletTotalMaintenanceMarginRequirementInTriplePips = arguments
      .liquidatingWalletTotalMaintenanceMarginRequirementInTriplePips;
    _validateExitQuoteQuantity(balanceStruct, validateExitQuoteQuantityArguments);
  }

  function _validateDeleverageQuoteQuantityAndUpdatePositions(
    ValidateDeleverageQuoteQuantityArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private {
    Market memory market = _validateDeleverageQuoteQuantity(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    _updatePositionsForDeleverage(
      arguments.acquisitionDeleverageArguments,
      arguments.exitFundWallet,
      market,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function _validateExitQuoteQuantity(
    Balance memory balanceStruct,
    ValidateExitQuoteQuantityArguments memory arguments
  ) private pure {
    if (arguments.deleveragePriceStrategy == WalletExitAcquisitionDeleveragePriceStrategy.ExitPrice) {
      LiquidationValidations.validateQuoteQuantityAtExitPrice(
        // Calculate the cost basis of the base quantity being liquidated while observing signedness
        Math.multiplyPipsByFraction(
          balanceStruct.costBasis,
          arguments.liquidationBaseQuantity,
          // IF simulation explicitly validates non-zero position size, otherwise implicitly validated non-zero by
          // `Validations.loadAndValidateActiveMarket`
          Math.toInt64(Math.abs(balanceStruct.balance))
        ),
        arguments.indexPrice,
        arguments.liquidationBaseQuantity,
        arguments.liquidationQuoteQuantity
      );
    } else {
      LiquidationValidations.validateQuoteQuantityAtBankruptcyPrice(
        arguments.indexPrice,
        arguments.liquidationBaseQuantity,
        arguments.liquidationQuoteQuantity,
        arguments.maintenanceMarginFraction,
        arguments.liquidatingWalletTotalAccountValueInDoublePips,
        arguments.liquidatingWalletTotalMaintenanceMarginRequirementInTriplePips
      );
    }
  }
}
