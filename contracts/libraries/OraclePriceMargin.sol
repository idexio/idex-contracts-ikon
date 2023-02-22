// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { Funding } from "./Funding.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Math } from "./Math.sol";
import { Balance, FundingMultiplierQuartet, Market, MarketOverrides } from "./Structs.sol";

library OraclePriceMargin {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;

  // solhint-disable-next-line func-name-mixedcase
  function loadQuoteQuantityAvailableForExitWithdrawalIncludingOutstandingWalletFunding_delegatecall(
    address exitFundWallet,
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
      _loadTotalAccountValue(
        outstandingWalletFunding,
        wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      );
  }

  // solhint-disable-next-line func-name-mixedcase
  function loadTotalInitialMarginRequirement_delegatecall(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (uint64 initialMarginRequirement) {
    return
      loadTotalInitialMarginRequirement(
        wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
  }

  // solhint-disable-next-line func-name-mixedcase
  function loadTotalMaintenanceMarginRequirement_delegatecall(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (uint64 maintenanceMarginRequirement) {
    return
      loadTotalMaintenanceMarginRequirement(
        wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
  }

  function loadQuoteQuantityAvailableForExitWithdrawal(
    address exitFundWallet,
    int64 outstandingWalletFunding,
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64) {
    int64 quoteQuantityAvailableForExitWithdrawal = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
      wallet,
      Constants.QUOTE_ASSET_SYMBOL
    );

    if (wallet == exitFundWallet) {
      // The EF wallet can withdraw any positive quote balance
      return Math.max(0, quoteQuantityAvailableForExitWithdrawal + outstandingWalletFunding);
    }

    (
      int64 totalAccountValue,
      uint64 totalMaintenanceMarginRequirement
    ) = loadTotalAccountValueAndMaintenanceMarginRequirement(
        outstandingWalletFunding,
        wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      quoteQuantityAvailableForExitWithdrawal += _loadQuoteQuantityForPositionExit(
        baseAssetSymbols[i],
        totalAccountValue,
        totalMaintenanceMarginRequirement,
        wallet,
        balanceTracking,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
    }

    return quoteQuantityAvailableForExitWithdrawal;
  }

  function loadTotalAccountValueAndMaintenanceMarginRequirement(
    int64 outstandingWalletFunding,
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64 totalAccountValue, uint64 maintenanceMarginRequirement) {
    totalAccountValue = _loadTotalAccountValue(
      outstandingWalletFunding,
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );
    maintenanceMarginRequirement = loadTotalMaintenanceMarginRequirement(
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function loadTotalInitialMarginRequirement(
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
        wallet,
        balanceTracking
      );
    }
  }

  function loadTotalMaintenanceMarginRequirement(
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
        wallet,
        balanceTracking
      );
    }
  }

  function _loadMarginRequirement(
    uint64 marginFraction,
    Market memory market,
    address wallet,
    BalanceTracking.Storage storage balanceTracking
  ) private view returns (uint64) {
    return
      Math.abs(
        Math.multiplyPipsByFraction(
          Math.multiplyPipsByFraction(
            balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol),
            int64(market.loadOracleFeedPrice()),
            int64(Constants.PIP_PRICE_MULTIPLIER)
          ),
          int64(marginFraction),
          int64(Constants.PIP_PRICE_MULTIPLIER)
        )
      );
  }

  function _loadQuoteQuantityForPositionExit(
    string memory baseAssetSymbol,
    int64 totalAccountValue,
    uint64 totalMaintenanceMarginRequirement,
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (int64) {
    Balance memory balanceStruct = balanceTracking.loadBalanceStructFromMigrationSourceIfNeeded(
      wallet,
      baseAssetSymbol
    );
    Market memory market = marketsByBaseAssetSymbol[baseAssetSymbol];

    uint64 quoteQuantityForPosition = LiquidationValidations.calculateExitQuoteQuantity(
      balanceStruct.costBasis,
      market.loadOracleFeedPrice(),
      market
        .loadMarketWithOverridesForWallet(wallet, marketOverridesByBaseAssetSymbolAndWallet)
        .overridableFields
        .maintenanceMarginFraction,
      balanceStruct.balance,
      totalAccountValue,
      totalMaintenanceMarginRequirement
    );

    // For short positions, the wallet gives quote to close the position so subtract. For long positions, the wallet
    // receives quote to close so add
    if (balanceStruct.balance < 0) {
      return -1 * int64(quoteQuantityForPosition);
    }

    return int64(quoteQuantityForPosition);
  }

  function _loadTotalAccountValue(
    int64 outstandingWalletFunding,
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (int64 totalAccountValue) {
    totalAccountValue =
      balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, Constants.QUOTE_ASSET_SYMBOL) +
      outstandingWalletFunding;

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      Market memory market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];

      totalAccountValue += Math.multiplyPipsByFraction(
        balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol),
        int64(market.loadOracleFeedPrice()),
        int64(Constants.PIP_PRICE_MULTIPLIER)
      );
    }
  }
}
