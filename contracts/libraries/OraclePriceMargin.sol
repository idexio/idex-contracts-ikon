// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { Funding } from "./Funding.sol";
import { IOraclePriceAdapter } from "./Interfaces.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Math } from "./Math.sol";
import { Balance, FundingMultiplierQuartet, Market, MarketOverrides } from "./Structs.sol";

library OraclePriceMargin {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;

  struct LoadQuoteQuantityForPositionExitArguments {
    string baseAssetSymbol;
    int64 exitAccountValue;
    IOraclePriceAdapter oraclePriceAdapter;
    int64 totalAccountValue;
    uint64 totalMaintenanceMarginRequirement;
    address wallet;
  }

  // solhint-disable-next-line func-name-mixedcase
  function loadQuoteQuantityAvailableForExitWithdrawalIncludingOutstandingWalletFunding_delegatecall(
    address exitFundWallet,
    IOraclePriceAdapter oraclePriceAdapter,
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (int64) {
    int64 outstandingWalletFunding = Funding.loadOutstandingWalletFunding(
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );
    return
      loadQuoteQuantityAvailableForExitWithdrawal(
        exitFundWallet,
        oraclePriceAdapter,
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
    IOraclePriceAdapter oraclePriceAdapter,
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (int64) {
    int64 outstandingWalletFunding = Funding.loadOutstandingWalletFunding(
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketsByBaseAssetSymbol
    );

    return
      loadTotalAccountValue(
        oraclePriceAdapter,
        outstandingWalletFunding,
        wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      );
  }

  // solhint-disable-next-line func-name-mixedcase
  function loadTotalInitialMarginRequirement_delegatecall(
    IOraclePriceAdapter oraclePriceAdapter,
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (uint64 initialMarginRequirement) {
    return
      loadTotalInitialMarginRequirement(
        oraclePriceAdapter,
        wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
  }

  // solhint-disable-next-line func-name-mixedcase
  function loadTotalMaintenanceMarginRequirement_delegatecall(
    IOraclePriceAdapter oraclePriceAdapter,
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (uint64 maintenanceMarginRequirement) {
    return
      loadTotalMaintenanceMarginRequirement(
        oraclePriceAdapter,
        wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
  }

  function loadExitAccountValueAndTotalAccountValueAndMaintenanceMarginRequirement(
    IOraclePriceAdapter oraclePriceAdapter,
    int64 outstandingWalletFunding,
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64 exitAccountValue, int64 totalAccountValue, uint64 maintenanceMarginRequirement) {
    exitAccountValue = _loadExitAccountValue(
      oraclePriceAdapter,
      outstandingWalletFunding,
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );
    totalAccountValue = loadTotalAccountValue(
      oraclePriceAdapter,
      outstandingWalletFunding,
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );
    maintenanceMarginRequirement = loadTotalMaintenanceMarginRequirement(
      oraclePriceAdapter,
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function loadQuoteQuantityAvailableForExitWithdrawal(
    address exitFundWallet,
    IOraclePriceAdapter oraclePriceAdapter,
    int64 outstandingWalletFunding,
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64 quoteQuantityAvailableForExitWithdrawal) {
    quoteQuantityAvailableForExitWithdrawal = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
      wallet,
      Constants.QUOTE_ASSET_SYMBOL
    );
    quoteQuantityAvailableForExitWithdrawal += outstandingWalletFunding;

    if (wallet == exitFundWallet) {
      // The EF wallet can withdraw any positive quote balance
      return Math.max(0, quoteQuantityAvailableForExitWithdrawal);
    }

    LoadQuoteQuantityForPositionExitArguments memory loadQuoteQuantityForPositionExitArguments;
    loadQuoteQuantityForPositionExitArguments.oraclePriceAdapter = oraclePriceAdapter;
    loadQuoteQuantityForPositionExitArguments.wallet = wallet;
    (
      loadQuoteQuantityForPositionExitArguments.exitAccountValue,
      loadQuoteQuantityForPositionExitArguments.totalAccountValue,
      loadQuoteQuantityForPositionExitArguments.totalMaintenanceMarginRequirement
    ) = loadExitAccountValueAndTotalAccountValueAndMaintenanceMarginRequirement(
      oraclePriceAdapter,
      outstandingWalletFunding,
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      loadQuoteQuantityForPositionExitArguments.baseAssetSymbol = baseAssetSymbols[i];
      quoteQuantityAvailableForExitWithdrawal += _loadQuoteQuantityForPositionExit(
        loadQuoteQuantityForPositionExitArguments,
        balanceTracking,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    }

    return quoteQuantityAvailableForExitWithdrawal;
  }

  function loadTotalAccountValue(
    IOraclePriceAdapter oraclePriceAdapter,
    int64 outstandingWalletFunding,
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64 totalAccountValue) {
    totalAccountValue =
      balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, Constants.QUOTE_ASSET_SYMBOL) +
      outstandingWalletFunding;

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      Market memory market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];

      totalAccountValue += Math.multiplyPipsByFraction(
        balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol),
        int64(oraclePriceAdapter.loadPriceForBaseAssetSymbol(market.baseAssetSymbol)),
        int64(Constants.PIP_PRICE_MULTIPLIER)
      );
    }
  }

  function loadTotalInitialMarginRequirement(
    IOraclePriceAdapter oraclePriceAdapter,
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (uint64 initialMarginRequirement) {
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      Market memory market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];

      initialMarginRequirement += _loadMarginRequirement(
        market.loadInitialMarginFractionForWallet(
          balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol),
          wallet,
          marketOverridesByBaseAssetSymbolAndWallet
        ),
        market,
        oraclePriceAdapter,
        wallet,
        balanceTracking
      );
    }
  }

  function loadTotalMaintenanceMarginRequirement(
    IOraclePriceAdapter oraclePriceAdapter,
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (uint64 maintenanceMarginRequirement) {
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      Market memory market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];

      maintenanceMarginRequirement += _loadMarginRequirement(
        market
          .loadMarketWithOverridesForWallet(wallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maintenanceMarginFraction,
        market,
        oraclePriceAdapter,
        wallet,
        balanceTracking
      );
    }
  }

  function _loadExitAccountValue(
    IOraclePriceAdapter oraclePriceAdapter,
    int64 outstandingWalletFunding,
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (int64 exitAccountValue) {
    exitAccountValue =
      balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, Constants.QUOTE_ASSET_SYMBOL) +
      outstandingWalletFunding;

    Balance memory balanceStruct;
    Market memory market;
    uint64 quoteQuantityForPosition;

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      balanceStruct = balanceTracking.loadBalanceStructFromMigrationSourceIfNeeded(wallet, baseAssetSymbols[i]);
      market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];

      quoteQuantityForPosition = LiquidationValidations.calculateQuoteQuantityAtExitPrice(
        balanceStruct.costBasis,
        oraclePriceAdapter.loadPriceForBaseAssetSymbol(market.baseAssetSymbol),
        balanceStruct.balance
      );

      if (balanceStruct.balance < 0) {
        // Short positions have negative value
        exitAccountValue -= int64(quoteQuantityForPosition);
      } else {
        // Long positions have positive value
        exitAccountValue += int64(quoteQuantityForPosition);
      }
    }
  }

  function _loadMarginRequirement(
    uint64 marginFraction,
    Market memory market,
    IOraclePriceAdapter oraclePriceAdapter,
    address wallet,
    BalanceTracking.Storage storage balanceTracking
  ) private view returns (uint64) {
    return
      Math.abs(
        Math.multiplyPipsByFraction(
          Math.multiplyPipsByFraction(
            balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol),
            int64(oraclePriceAdapter.loadPriceForBaseAssetSymbol(market.baseAssetSymbol)),
            int64(Constants.PIP_PRICE_MULTIPLIER)
          ),
          int64(marginFraction),
          int64(Constants.PIP_PRICE_MULTIPLIER)
        )
      );
  }

  function _loadQuoteQuantityForPositionExit(
    LoadQuoteQuantityForPositionExitArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (int64) {
    Balance memory balanceStruct = balanceTracking.loadBalanceStructFromMigrationSourceIfNeeded(
      arguments.wallet,
      arguments.baseAssetSymbol
    );
    Market memory market = marketsByBaseAssetSymbol[arguments.baseAssetSymbol];
    uint64 oraclePrice = arguments.oraclePriceAdapter.loadPriceForBaseAssetSymbol(market.baseAssetSymbol);

    uint64 quoteQuantityForPosition = arguments.exitAccountValue <= 0
      ? LiquidationValidations.calculateQuoteQuantityAtBankruptcyPrice(
        oraclePrice,
        market
          .loadMarketWithOverridesForWallet(arguments.wallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maintenanceMarginFraction,
        balanceStruct.balance,
        arguments.totalAccountValue,
        arguments.totalMaintenanceMarginRequirement
      )
      : LiquidationValidations.calculateQuoteQuantityAtExitPrice(
        balanceStruct.costBasis,
        oraclePrice,
        balanceStruct.balance
      );

    // For short positions, the wallet gives quote to close the position so subtract. For long positions, the wallet
    // receives quote to close so add
    if (balanceStruct.balance < 0) {
      return -1 * int64(quoteQuantityForPosition);
    }

    return int64(quoteQuantityForPosition);
  }
}
