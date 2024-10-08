// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { BalanceTracking } from "./BalanceTracking.sol";
import { DeleverageType } from "./Enums.sol";
import { ExitFund } from "./ExitFund.sol";
import { Funding } from "./Funding.sol";
import { IndexPriceMargin } from "./IndexPriceMargin.sol";
import { LiquidationValidations } from "./LiquidationValidations.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Math } from "./Math.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { Validations } from "./Validations.sol";
import { Balance, ClosureDeleverageArguments, FundingMultiplierQuartet, Market, MarketOverrides } from "./Structs.sol";

library ClosureDeleveraging {
  using BalanceTracking for BalanceTracking.Storage;
  using MarketHelper for Market;
  using SortedStringSet for string[];

  /**
   * @notice Emitted when the Dispatcher Wallet submits an Exit Fund closure deleverage with `deleverageExitFundClosure`
   */
  event DeleveragedExitFundClosure(
    string baseAssetSymbol,
    address counterpartyWallet,
    address exitFundWallet,
    uint64 liquidationBaseQuantity,
    uint64 liquidationQuoteQuantity
  );

  /**
   * @notice Emitted when the Dispatcher Wallet submits an Insurance Fund closure deleverage with
   * `deleverageInsuranceFundClosure`
   */
  event DeleveragedInsuranceFundClosure(
    string baseAssetSymbol,
    address counterpartyWallet,
    address insuranceFundWallet,
    uint64 liquidationBaseQuantity,
    uint64 liquidationQuoteQuantity
  );

  // solhint-disable-next-line func-name-mixedcase
  function deleverage_delegatecall(
    ClosureDeleverageArguments memory arguments,
    DeleverageType deleverageType,
    uint256 exitFundPositionOpenedAtBlockTimestamp,
    address exitFundWallet,
    address insuranceFundWallet,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public returns (uint256) {
    require(arguments.liquidatingWallet != arguments.counterpartyWallet, "Cannot liquidate wallet against itself");
    require(arguments.counterpartyWallet != exitFundWallet, "Cannot deleverage EF");
    require(arguments.counterpartyWallet != insuranceFundWallet, "Cannot deleverage IF");
    if (deleverageType == DeleverageType.ExitFundClosure) {
      require(arguments.liquidatingWallet == exitFundWallet, "Liquidating wallet must be EF");
    } else {
      // DeleverageType.InsuranceFundClosure
      require(arguments.liquidatingWallet == insuranceFundWallet, "Liquidating wallet must be IF");
    }

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
      deleverageType,
      exitFundWallet,
      balanceTracking,
      baseAssetSymbolsWithOpenPositionsByWallet,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
      marketOverridesByBaseAssetSymbolAndWallet,
      marketsByBaseAssetSymbol
    );

    // EF closure deleveraging can potentially change the `exitFundPositionOpenedAtBlockTimestamp` by setting it to
    // zero, whereas IF closure cannot
    if (deleverageType == DeleverageType.ExitFundClosure) {
      _emitDeleveragedExitFundClosure(arguments, exitFundWallet);

      return
        ExitFund.getExitFundPositionOpenedAtBlockTimestamp(
          exitFundPositionOpenedAtBlockTimestamp,
          exitFundWallet,
          balanceTracking,
          baseAssetSymbolsWithOpenPositionsByWallet
        );
    } else {
      _emitDeleveragedInsuranceFundClosure(arguments, insuranceFundWallet);

      // IF closure never changes `exitFundPositionOpenedAtBlockTimestamp`
      return exitFundPositionOpenedAtBlockTimestamp;
    }
  }

  function _emitDeleveragedExitFundClosure(
    ClosureDeleverageArguments memory arguments,
    address exitFundWallet
  ) private {
    emit DeleveragedExitFundClosure(
      arguments.baseAssetSymbol,
      arguments.counterpartyWallet,
      exitFundWallet,
      arguments.liquidationBaseQuantity,
      arguments.liquidationQuoteQuantity
    );
  }

  function _emitDeleveragedInsuranceFundClosure(
    ClosureDeleverageArguments memory arguments,
    address insuranceFundWallet
  ) private {
    emit DeleveragedInsuranceFundClosure(
      arguments.baseAssetSymbol,
      arguments.counterpartyWallet,
      insuranceFundWallet,
      arguments.liquidationBaseQuantity,
      arguments.liquidationQuoteQuantity
    );
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

  function _validateQuoteQuantityForExitFundClosure(
    ClosureDeleverageArguments memory arguments,
    address exitFundWallet,
    Market memory market,
    int64 positionSize,
    BalanceTracking.Storage storage balanceTracking,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) private view {
    (int256 totalAccountValueInDoublePips, uint256 totalMaintenanceMarginRequirementInTriplePips) = IndexPriceMargin
    // Use margin calculation specific to EF that accounts for its unlimited leverage
      .loadTotalAccountValueInDoublePipsAndMaintenanceMarginRequirementInTriplePipsForExitFund(
        exitFundWallet,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      );

    // The provided liquidationBaseQuantity specifies how much of the position to liquidate, so we provide this
    // quantity as the position size to `LiquidationValidations.validateExitFundClosureQuoteQuantity` while observing
    // the same signedness
    LiquidationValidations.validateExitFundClosureQuoteQuantity(
      market.lastIndexPrice,
      Math.abs(positionSize) < market.overridableFields.minimumPositionSize,
      positionSize < 0
        ? (-1 * Math.toInt64(arguments.liquidationBaseQuantity))
        : Math.toInt64(arguments.liquidationBaseQuantity),
      arguments.liquidationQuoteQuantity,
      // Use market default values instead of wallet-specific overrides for the EF, since its margin fraction is zero
      market.overridableFields.maintenanceMarginFraction,
      totalAccountValueInDoublePips,
      totalMaintenanceMarginRequirementInTriplePips
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
      _validateQuoteQuantityForExitFundClosure(
        arguments,
        exitFundWallet,
        market,
        balanceStruct.balance,
        balanceTracking,
        baseAssetSymbolsWithOpenPositionsByWallet,
        marketsByBaseAssetSymbol
      );
    }

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
}
