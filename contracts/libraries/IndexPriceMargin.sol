// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { Funding } from "./Funding.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Math } from "./Math.sol";
import { FundingMultiplierQuartet, Market, MarketOverrides } from "./Structs.sol";

library IndexPriceMargin {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;

  struct ValidateInsuranceFundCannotLiquidateWalletArguments {
    address insuranceFundWallet;
    address liquidatingWallet;
    uint64[] liquidationQuoteQuantities;
    Market[] markets;
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
    int64 totalAccountValue = loadTotalAccountValue(
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
        int64(market.lastIndexPrice),
        int64(Constants.PIP_PRICE_MULTIPLIER)
      );
      totalInitialMarginRequirement += _loadMarginRequirement(
        market.loadInitialMarginFractionForWallet(positionSize, wallet, marketOverridesByBaseAssetSymbolAndWallet),
        market.lastIndexPrice,
        positionSize
      );
    }

    require(totalAccountValue >= int64(totalInitialMarginRequirement), "Initial margin requirement not met");
  }

  function loadTotalAccountValue(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64 totalAccountValue) {
    totalAccountValue = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, Constants.QUOTE_ASSET_SYMBOL);

    Market memory market;

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];

      totalAccountValue += Math.multiplyPipsByFraction(
        balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol),
        int64(market.lastIndexPrice),
        int64(Constants.PIP_PRICE_MULTIPLIER)
      );
    }
  }

  // Identical to `loadTotalAccountValueAndMaintenanceMarginRequirement` except no wallet-specific overrides are
  // observed for the EF
  function loadTotalAccountValueAndMaintenanceMarginRequirementForExitFund(
    address exitFundWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) {
    totalAccountValue = loadTotalAccountValue(
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

      totalMaintenanceMarginRequirement += _loadMarginRequirement(
        market.overridableFields.maintenanceMarginFraction,
        market.lastIndexPrice,
        positionSize
      );
    }
  }

  function loadTotalAccountValueAndMaintenanceMarginRequirement(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) {
    totalAccountValue = loadTotalAccountValue(
      wallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );
    totalMaintenanceMarginRequirement = loadTotalMaintenanceMarginRequirement(
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

  function loadTotalMaintenanceMarginRequirement(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (uint64 maintenanceMarginRequirement) {
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

  /**
   * @param arguments Already validated by calling function
   */
  function validateInsuranceFundCannotLiquidateWallet(
    ValidateInsuranceFundCannotLiquidateWalletArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal view {
    (
      int64 insuranceFundTotalAccountValue,
      uint64 insuranceFundTotalInitialMarginRequirement,
      bool isInsuranceFundMaximumPositionSizeExceeded
    ) = _loadInsuranceFundTotalAccountValueAndInitialMarginRequirementAfterLiquidationAcquisition(
        arguments,
        balanceTracking,
        marketOverridesByBaseAssetSymbolAndWallet
      );

    // IF cannot acquire if doing so would exceed its max position size or bring it below its initial margin requirement
    require(
      isInsuranceFundMaximumPositionSizeExceeded ||
        insuranceFundTotalAccountValue < int64(insuranceFundTotalInitialMarginRequirement),
      "Insurance fund can acquire"
    );
  }

  function _loadInsuranceFundTotalAccountValueAndInitialMarginRequirementAfterLiquidationAcquisition(
    ValidateInsuranceFundCannotLiquidateWalletArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  )
    private
    view
    returns (
      int64 insuranceFundTotalAccountValue,
      uint64 insuranceFundTotalInitialMarginRequirement,
      bool isInsuranceFundMaximumPositionSizeExceeded
    )
  {
    insuranceFundTotalAccountValue = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
      arguments.insuranceFundWallet,
      Constants.QUOTE_ASSET_SYMBOL
    );

    int256 insuranceFundPositionSizeAfterAcquisition;
    int64 liquidatingWalletPositionSize;

    for (uint8 i = 0; i < arguments.markets.length; i++) {
      liquidatingWalletPositionSize = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
        arguments.liquidatingWallet,
        arguments.markets[i].baseAssetSymbol
      );

      if (liquidatingWalletPositionSize < 0) {
        // IF receives quote to acquire short position
        insuranceFundTotalAccountValue += int64(arguments.liquidationQuoteQuantities[i]);
      } else {
        // IF gives quote to acquire long position
        insuranceFundTotalAccountValue -= int64(arguments.liquidationQuoteQuantities[i]);
      }

      // Calculate Insurance Fund position size after acquiring position
      insuranceFundPositionSizeAfterAcquisition =
        int256(
          balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
            arguments.insuranceFundWallet,
            arguments.markets[i].baseAssetSymbol
          )
        ) +
        liquidatingWalletPositionSize;

      // If acquiring this position exceeds the IF's maximum position size for the market, then it cannot acquire
      // and we can stop here
      isInsuranceFundMaximumPositionSizeExceeded =
        insuranceFundPositionSizeAfterAcquisition > type(int64).max ||
        insuranceFundPositionSizeAfterAcquisition < type(int64).min ||
        Math.abs(int64(insuranceFundPositionSizeAfterAcquisition)) >
        arguments
          .markets[i]
          .loadMarketWithOverridesForWallet(arguments.insuranceFundWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maximumPositionSize;
      if (isInsuranceFundMaximumPositionSizeExceeded) {
        // IF cannot acquire position, break here without completing IF margin calculations
        break;
      }

      // If position is non-zero then include in total account value
      if (insuranceFundPositionSizeAfterAcquisition != 0) {
        // Accumulate account value by adding signed position value
        insuranceFundTotalAccountValue += Math.multiplyPipsByFraction(
          int64(insuranceFundPositionSizeAfterAcquisition),
          int64(arguments.markets[i].lastIndexPrice),
          int64(Constants.PIP_PRICE_MULTIPLIER)
        );
        // Accumulate margin requirement
        insuranceFundTotalInitialMarginRequirement += Math.abs(
          Math.multiplyPipsByFraction(
            Math.multiplyPipsByFraction(
              int64(insuranceFundPositionSizeAfterAcquisition),
              int64(arguments.markets[i].lastIndexPrice),
              int64(Constants.PIP_PRICE_MULTIPLIER)
            ),
            int64(
              arguments.markets[i].loadInitialMarginFractionForWallet(
                int64(insuranceFundPositionSizeAfterAcquisition),
                arguments.insuranceFundWallet,
                marketOverridesByBaseAssetSymbolAndWallet
              )
            ),
            int64(Constants.PIP_PRICE_MULTIPLIER)
          )
        );
      }
    }
  }

  function _loadMarginRequirement(
    uint64 marginFraction,
    uint64 lastIndexPrice,
    int64 positionSize
  ) private pure returns (uint64) {
    return
      Math.abs(
        Math.multiplyPipsByFraction(
          Math.multiplyPipsByFraction(positionSize, int64(lastIndexPrice), int64(Constants.PIP_PRICE_MULTIPLIER)),
          int64(marginFraction),
          int64(Constants.PIP_PRICE_MULTIPLIER)
        )
      );
  }
}
