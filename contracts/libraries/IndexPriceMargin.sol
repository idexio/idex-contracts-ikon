// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { Funding } from "./Funding.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Math } from "./Math.sol";
import { Balance, FundingMultiplierQuartet, Market, MarketOverrides } from "./Structs.sol";

library IndexPriceMargin {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;

  // solhint-disable-next-line func-name-mixedcase
  function loadTotalAccountValueIncludingOutstandingWalletFunding_delegatecall(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol,
    mapping(address => uint64) storage pendingDepositQuantityByWallet
  ) public view returns (int64) {
    int64 totalAccountValue = _loadTotalAccountValue(
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    return
      totalAccountValue +
      Funding.loadOutstandingWalletFunding(
        wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        fundingMultipliersByBaseAssetSymbol,
        lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
        marketsByBaseAssetSymbol
      ) +
      Math.toInt64(pendingDepositQuantityByWallet[wallet]);
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
      _loadTotalInitialMarginRequirement(
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
      _loadTotalMaintenanceMarginRequirement(
        wallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketOverridesByBaseAssetSymbolAndWallet,
        marketsByBaseAssetSymbol
      );
  }

  function loadTotalAccountValueInDoublePipsAndMaintenanceMarginRequirementInTriplePips(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  )
    internal
    view
    returns (int256 totalAccountValueInDoublePips, uint256 totalMaintenanceMarginRequirementInTriplePips)
  {
    totalAccountValueInDoublePips = _loadTotalAccountValueInDoublePips(
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );
    totalMaintenanceMarginRequirementInTriplePips = _loadTotalMaintenanceMarginRequirementInTriplePips(
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function loadTotalExitAccountValueAndAccountValueInDoublePipsAndMaintenanceMarginRequirementInTriplePips(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  )
    internal
    view
    returns (
      int64 totalExitAccountValue,
      int256 totalAccountValueInDoublePips,
      uint256 totalMaintenanceMarginRequirementInTriplePips
    )
  {
    totalExitAccountValue = _loadTotalExitAccountValue(
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );
    totalAccountValueInDoublePips = _loadTotalAccountValueInDoublePips(
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );
    totalMaintenanceMarginRequirementInTriplePips = _loadTotalMaintenanceMarginRequirementInTriplePips(
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  // No wallet-specific overrides are observed for the EF
  function loadTotalAccountValueInDoublePipsAndMaintenanceMarginRequirementInTriplePipsForExitFund(
    address exitFundWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  )
    internal
    view
    returns (int256 totalAccountValueInDoublePips, uint256 totalMaintenanceMarginRequirementInTriplePips)
  {
    totalAccountValueInDoublePips = _loadTotalAccountValueInDoublePips(
      exitFundWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    Market memory market;
    int64 positionSize;
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[exitFundWallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      positionSize = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(exitFundWallet, market.baseAssetSymbol);

      totalMaintenanceMarginRequirementInTriplePips += _loadMarginRequirementInTriplePips(
        market.overridableFields.maintenanceMarginFraction,
        market.lastIndexPrice,
        positionSize
      );
    }
  }

  function validateInitialMarginRequirement(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view {
    int64 totalAccountValue = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
      wallet,
      Constants.QUOTE_ASSET_SYMBOL
    );
    uint64 totalInitialMarginRequirement;

    Market memory market;
    int64 positionSize;
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      positionSize = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol);

      totalAccountValue += Math.multiplyPipsByFraction(
        positionSize,
        Math.toInt64(market.lastIndexPrice),
        Math.toInt64(Constants.PIP_PRICE_MULTIPLIER)
      );
      totalInitialMarginRequirement += _loadMarginRequirement(
        market.loadInitialMarginFractionForWallet(positionSize, wallet, marketOverridesByBaseAssetSymbolAndWallet),
        market.lastIndexPrice,
        positionSize
      );
    }

    require(totalAccountValue >= Math.toInt64(totalInitialMarginRequirement), "Initial margin requirement not met");
  }

  function validateMaintenanceMarginRequirement(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view {
    int64 totalAccountValue = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
      wallet,
      Constants.QUOTE_ASSET_SYMBOL
    );
    uint64 totalMaintenanceMarginRequirement;

    Market memory market;
    int64 positionSize;
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      positionSize = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol);

      totalAccountValue += Math.multiplyPipsByFraction(
        positionSize,
        Math.toInt64(market.lastIndexPrice),
        Math.toInt64(Constants.PIP_PRICE_MULTIPLIER)
      );
      totalMaintenanceMarginRequirement += _loadMarginRequirement(
        market
          .loadMarketWithOverridesForWallet(wallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maintenanceMarginFraction,
        market.lastIndexPrice,
        positionSize
      );
    }

    require(
      totalAccountValue >= Math.toInt64(totalMaintenanceMarginRequirement),
      "Maintenance margin requirement not met"
    );
  }

  function _loadMarginRequirement(
    uint64 marginFraction,
    uint64 lastIndexPrice,
    int64 positionSize
  ) private pure returns (uint64) {
    return
      Math.multiplyPipsByFraction(
        Math.multiplyPipsByFraction(Math.abs(positionSize), lastIndexPrice, Constants.PIP_PRICE_MULTIPLIER),
        marginFraction,
        Constants.PIP_PRICE_MULTIPLIER
      );
  }

  function _loadMarginRequirementInTriplePips(
    uint64 marginFraction,
    uint64 lastIndexPrice,
    int64 positionSize
  ) private pure returns (uint256) {
    return uint256(Math.abs(positionSize)) * lastIndexPrice * marginFraction;
  }

  function _loadTotalAccountValue(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (int64 totalAccountValue) {
    totalAccountValue = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, Constants.QUOTE_ASSET_SYMBOL);

    Market memory market;

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];

      totalAccountValue += Math.multiplyPipsByFraction(
        balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol),
        Math.toInt64(market.lastIndexPrice),
        Math.toInt64(Constants.PIP_PRICE_MULTIPLIER)
      );
    }
  }

  function _loadTotalAccountValueInDoublePips(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (int256 totalAccountValueInDoublePips) {
    totalAccountValueInDoublePips =
      int256(balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, Constants.QUOTE_ASSET_SYMBOL)) *
      Math.toInt64(Constants.PIP_PRICE_MULTIPLIER);

    Market memory market;

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];

      totalAccountValueInDoublePips +=
        int256(balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol)) *
        Math.toInt64(market.lastIndexPrice);
    }
  }

  function _loadTotalExitAccountValue(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (int64 exitAccountValue) {
    exitAccountValue = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, Constants.QUOTE_ASSET_SYMBOL);

    Balance memory balanceStruct;
    Market memory market;
    uint64 quoteQuantityForPosition;

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      balanceStruct = balanceTracking.loadBalanceStructFromMigrationSourceIfNeeded(wallet, baseAssetSymbols[i]);
      market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];

      quoteQuantityForPosition = LiquidationValidations.calculateQuoteQuantityAtExitPrice(
        balanceStruct.costBasis,
        market.lastIndexPrice,
        balanceStruct.balance
      );

      if (balanceStruct.balance < 0) {
        // Short positions have negative value
        exitAccountValue -= Math.toInt64(quoteQuantityForPosition);
      } else {
        // Long positions have positive value
        exitAccountValue += Math.toInt64(quoteQuantityForPosition);
      }
    }
  }

  function _loadTotalInitialMarginRequirement(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (uint64 initialMarginRequirement) {
    Market memory market;
    int64 positionSize;
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      positionSize = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol);

      initialMarginRequirement += _loadMarginRequirement(
        market.loadInitialMarginFractionForWallet(
          balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol),
          wallet,
          marketOverridesByBaseAssetSymbolAndWallet
        ),
        market.lastIndexPrice,
        positionSize
      );
    }
  }

  function _loadTotalMaintenanceMarginRequirement(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (uint64 maintenanceMarginRequirement) {
    Market memory market;
    int64 positionSize;
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      positionSize = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol);

      maintenanceMarginRequirement += _loadMarginRequirement(
        market
          .loadMarketWithOverridesForWallet(wallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maintenanceMarginFraction,
        market.lastIndexPrice,
        positionSize
      );
    }
  }

  function _loadTotalMaintenanceMarginRequirementInTriplePips(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view returns (uint256 maintenanceMarginRequirementInTriplePip) {
    Market memory market;
    int64 positionSize;
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      positionSize = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol);

      maintenanceMarginRequirementInTriplePip += _loadMarginRequirementInTriplePips(
        market
          .loadMarketWithOverridesForWallet(wallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maintenanceMarginFraction,
        market.lastIndexPrice,
        positionSize
      );
    }
  }
}
