// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { BalanceTracking } from "./BalanceTracking.sol";
import { Constants } from "./Constants.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Math } from "./Math.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { OnChainPriceFeedMargin } from "./OnChainPriceFeedMargin.sol";
import { Validations } from "./Validations.sol";
import { Balance, IndexPrice, Market, MarketOverrides } from "./Structs.sol";

library NonMutatingMargin {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;

  struct LoadArguments {
    address wallet;
    IndexPrice[] indexPrices;
    address[] indexPriceCollectionServiceWallets;
  }

  struct ValidateInsuranceFundCannotLiquidateWalletArguments {
    address insuranceFundWallet;
    address liquidatingWallet;
    uint64[] liquidationQuoteQuantities;
    Market[] markets;
    // Price values only, calling function should validate index price struct
    uint64[] indexPrices;
    address[] indexPriceCollectionServiceWallets;
  }

  // solhint-disable-next-line func-name-mixedcase
  function loadQuoteQuantityAvailableForExitWithdrawal_delegatecall(
    address wallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (uint64) {
    int64 quoteQuantityAvailableForExitWithdrawal = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
      wallet,
      Constants.QUOTE_ASSET_SYMBOL
    );

    (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) = OnChainPriceFeedMargin
      .loadTotalAccountValueAndMaintenanceMarginRequirement(
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

    // Quote quantity will never be negative per design of exit quote calculations
    return Math.abs(quoteQuantityAvailableForExitWithdrawal);
  }

  // solhint-disable-next-line func-name-mixedcase
  function loadTotalInitialMarginRequirement_delegatecall(
    address wallet,
    IndexPrice[] memory indexPrices,
    address[] memory indexPriceCollectionServiceWallets,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (uint64 initialMarginRequirement) {
    return
      indexPrices.length > 0
        ? loadTotalInitialMarginRequirement(
          wallet,
          indexPrices,
          indexPriceCollectionServiceWallets,
          balanceTracking,
          baseAssetSymbolsWithOpenPositionsByWallet,
          marketOverridesByBaseAssetSymbolAndWallet,
          marketsByBaseAssetSymbol
        )
        : OnChainPriceFeedMargin.loadTotalInitialMarginRequirement(
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
    IndexPrice[] memory indexPrices,
    address[] memory indexPriceCollectionServiceWallets,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public view returns (uint64 maintenanceMarginRequirement) {
    return
      indexPrices.length > 0
        ? loadTotalMaintenanceMarginRequirement(
          wallet,
          indexPrices,
          indexPriceCollectionServiceWallets,
          balanceTracking,
          baseAssetSymbolsWithOpenPositionsByWallet,
          marketOverridesByBaseAssetSymbolAndWallet,
          marketsByBaseAssetSymbol
        )
        : OnChainPriceFeedMargin.loadTotalMaintenanceMarginRequirement(
          wallet,
          balanceTracking,
          baseAssetSymbolsWithOpenPositionsByWallet,
          marketOverridesByBaseAssetSymbolAndWallet,
          marketsByBaseAssetSymbol
        );
  }

  function loadTotalAccountValue(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64 totalAccountValue) {
    totalAccountValue = balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
      arguments.wallet,
      Constants.QUOTE_ASSET_SYMBOL
    );

    Market memory market;

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];
      Validations.validateIndexPrice(arguments.indexPrices[i], arguments.indexPriceCollectionServiceWallets, market);

      totalAccountValue += Math.multiplyPipsByFraction(
        balanceTracking.loadBalanceFromMigrationSourceIfNeeded(arguments.wallet, market.baseAssetSymbol),
        int64(arguments.indexPrices[i].price),
        int64(Constants.PIP_PRICE_MULTIPLIER)
      );
    }
  }

  // Identical to `loadTotalAccountValueAndMaintenanceMarginRequirement` except no wallet-specific overrides are
  // observed for the EF
  function loadTotalAccountValueAndMaintenanceMarginRequirementForExitFund(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) {
    totalAccountValue = loadTotalAccountValue(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );

    Market memory market;
    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[arguments.wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];

      totalMaintenanceMarginRequirement += _loadMarginRequirement(
        arguments.indexPrices[i],
        arguments.indexPriceCollectionServiceWallets,
        market.overridableFields.maintenanceMarginFraction,
        market,
        arguments.wallet,
        balanceTracking
      );
    }
  }

  function loadTotalAccountValueAndMaintenanceMarginRequirement(
    LoadArguments memory arguments,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (int64 totalAccountValue, uint64 totalMaintenanceMarginRequirement) {
    totalAccountValue = loadTotalAccountValue(
      arguments,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketsByBaseAssetSymbol
    );
    totalMaintenanceMarginRequirement = loadTotalMaintenanceMarginRequirement(
      arguments.wallet,
      arguments.indexPrices,
      arguments.indexPriceCollectionServiceWallets,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );
  }

  function loadTotalInitialMarginRequirement(
    address wallet,
    IndexPrice[] memory indexPrices,
    address[] memory indexPriceCollectionServiceWallets,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (uint64 initialMarginRequirement) {
    Market memory market;

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];

      initialMarginRequirement += _loadMarginRequirement(
        indexPrices[i],
        indexPriceCollectionServiceWallets,
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
    IndexPrice[] memory indexPrices,
    address[] memory indexPriceCollectionServiceWallets,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (uint64 maintenanceMarginRequirement) {
    Market memory market;

    string[] memory baseAssetSymbols = baseAssetSymbolsWithOpenPositionsByWallet[wallet];
    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      market = marketsByBaseAssetSymbol[baseAssetSymbols[i]];

      maintenanceMarginRequirement += _loadMarginRequirement(
        indexPrices[i],
        indexPriceCollectionServiceWallets,
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
      bool isMaximumPositionSizeExceeded
    ) = _loadInsuranceFundTotalAccountValueAndInitialMarginRequirementAfterLiquidationAcquisition(
        arguments,
        balanceTracking,
        marketOverridesByBaseAssetSymbolAndWallet
      );

    // IF cannot acquire if doing so would exceed its max position size or bring it below its initial margin requirement
    require(
      isMaximumPositionSizeExceeded ||
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
      uint64 totalInitialMarginRequirement,
      bool isMaximumPositionSizeExceeded
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
        balanceTracking.loadBalanceFromMigrationSourceIfNeeded(
          arguments.insuranceFundWallet,
          arguments.markets[i].baseAssetSymbol
        ) +
        liquidatingWalletPositionSize;

      // If acquiring this position exceeds the IF's maximum position size for the market, then it cannot acquire
      // and we can stop here
      isMaximumPositionSizeExceeded =
        insuranceFundPositionSizeAfterAcquisition >= 2 ** 63 ||
        insuranceFundPositionSizeAfterAcquisition <= -2 ** 63 ||
        Math.abs(int64(insuranceFundPositionSizeAfterAcquisition)) >
        arguments
          .markets[i]
          .loadMarketWithOverridesForWallet(arguments.insuranceFundWallet, marketOverridesByBaseAssetSymbolAndWallet)
          .overridableFields
          .maximumPositionSize;
      if (isMaximumPositionSizeExceeded) {
        break;
      }

      // If position is non-zero then include in total account value
      if (insuranceFundPositionSizeAfterAcquisition != 0) {
        // Accumulate account value by adding signed position value
        insuranceFundTotalAccountValue += Math.multiplyPipsByFraction(
          int64(insuranceFundPositionSizeAfterAcquisition),
          int64(arguments.indexPrices[i]),
          int64(Constants.PIP_PRICE_MULTIPLIER)
        );
        // Accumulate margin requirement
        totalInitialMarginRequirement += Math.abs(
          Math.multiplyPipsByFraction(
            Math.multiplyPipsByFraction(
              int64(insuranceFundPositionSizeAfterAcquisition),
              int64(arguments.indexPrices[i]),
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
    IndexPrice memory indexPrice,
    address[] memory indexPriceCollectionServiceWallets,
    uint64 marginFraction,
    Market memory market,
    address wallet,
    BalanceTracking.Storage storage balanceTracking
  ) private view returns (uint64) {
    Validations.validateIndexPrice(indexPrice, indexPriceCollectionServiceWallets, market);

    return
      Math.abs(
        Math.multiplyPipsByFraction(
          Math.multiplyPipsByFraction(
            balanceTracking.loadBalanceFromMigrationSourceIfNeeded(wallet, market.baseAssetSymbol),
            int64(indexPrice.price),
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
      // Market indexed redundantly to avoid stack too deep error
      market.loadOnChainFeedPrice(),
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
}
