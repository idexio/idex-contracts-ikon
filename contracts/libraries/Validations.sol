// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { Constants } from "./Constants.sol";
import { Math } from "./Math.sol";
import { SortedStringSet } from "./SortedStringSet.sol";
import { String } from "./String.sol";
import { Market, OverridableMarketFields } from "./Structs.sol";

library Validations {
  using SortedStringSet for string[];

  // 0.005
  uint64 private constant _MIN_INITIAL_MARGIN_FRACTION = 500000;
  // 0.003
  uint64 private constant _MIN_MAINTENANCE_MARGIN_FRACTION = 300000;
  // 0.001
  uint64 private constant _MIN_INCREMENTAL_INITIAL_MARGIN_FRACTION = 100000;
  // Max int64 - 1
  uint64 private constant _MAX_MINIMUM_POSITION_SIZE = uint64(type(int64).max - 1);

  function isFeeQuantityValid(uint64 fee, uint64 total) internal pure returns (bool) {
    uint64 feeMultiplier = Math.multiplyPipsByFraction(fee, Constants.PIP_PRICE_MULTIPLIER, total);

    return feeMultiplier <= Constants.MAX_FEE_MULTIPLIER;
  }

  function loadAndValidateActiveMarket(
    string memory baseAssetSymbol,
    address liquidatingWallet,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (Market memory market) {
    market = marketsByBaseAssetSymbol[baseAssetSymbol];
    require(market.exists && market.isActive, "No active market found");

    require(
      baseAssetSymbolsWithOpenPositionsByWallet[liquidatingWallet].indexOf(baseAssetSymbol) !=
        SortedStringSet.NOT_FOUND,
      "Open position not found for market"
    );
  }

  function loadAndValidateInactiveMarket(
    string memory baseAssetSymbol,
    address liquidatingWallet,
    mapping(address => string[]) storage baseAssetSymbolsWithOpenPositionsByWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) internal view returns (Market memory market) {
    market = marketsByBaseAssetSymbol[baseAssetSymbol];
    require(market.exists && !market.isActive, "No inactive market found");

    require(
      baseAssetSymbolsWithOpenPositionsByWallet[liquidatingWallet].indexOf(baseAssetSymbol) !=
        SortedStringSet.NOT_FOUND,
      "Open position not found for market"
    );
  }

  // Validate reasonable limits on overridable market fields
  function validateOverridableMarketFields(OverridableMarketFields memory overridableFields) internal pure {
    require(
      overridableFields.initialMarginFraction >= _MIN_INITIAL_MARGIN_FRACTION,
      "Initial margin fraction below min"
    );
    require(
      overridableFields.maintenanceMarginFraction >= _MIN_MAINTENANCE_MARGIN_FRACTION,
      "Maintenance margin fraction below min"
    );
    require(
      overridableFields.incrementalInitialMarginFraction >= _MIN_INCREMENTAL_INITIAL_MARGIN_FRACTION,
      "Incremental initial margin fraction below min"
    );
    require(
      overridableFields.baselinePositionSize <= Constants.MAX_MAXIMUM_POSITION_SIZE,
      "Baseline position size exceeds max"
    );
    require(overridableFields.incrementalPositionSize > 0, "Incremental position size cannot be zero");
    require(
      overridableFields.maximumPositionSize <= Constants.MAX_MAXIMUM_POSITION_SIZE,
      "Maximum position size exceeds max"
    );
    require(overridableFields.minimumPositionSize <= _MAX_MINIMUM_POSITION_SIZE, "Minimum position size exceeds max");
  }
}
