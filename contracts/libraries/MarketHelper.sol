// SPDX-License-Identifier: LGPL-3.0-only

import { AssetUnitConversions } from "./AssetUnitConversions.sol";
import { Math } from "./Math.sol";
import { Market, MarketOverrides } from "./Structs.sol";

pragma solidity 0.8.18;

library MarketHelper {
  function loadOraclePrice(Market memory self) internal view returns (uint64 price) {
    (, int256 answer, , , ) = self.chainlinkPriceFeedAddress.latestRoundData();
    require(answer > 0, "Unexpected non-positive feed price");

    return AssetUnitConversions.assetUnitsToPips(uint256(answer), self.chainlinkPriceFeedAddress.decimals());
  }

  function loadInitialMarginFractionForWallet(
    Market memory market,
    int64 positionSize,
    address wallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal view returns (uint64) {
    Market memory marketWithOverrides = loadMarketWithOverridesForWallet(
      market,
      wallet,
      marketOverridesByBaseAssetSymbolAndWallet
    );

    uint64 absolutePositionSize = Math.abs(positionSize);
    if (absolutePositionSize <= marketWithOverrides.overridableFields.baselinePositionSize) {
      return marketWithOverrides.overridableFields.initialMarginFraction;
    }

    uint64 increments = Math.divideRoundUp(
      (absolutePositionSize - marketWithOverrides.overridableFields.baselinePositionSize),
      marketWithOverrides.overridableFields.incrementalPositionSize
    );
    return
      marketWithOverrides.overridableFields.initialMarginFraction +
      (increments * marketWithOverrides.overridableFields.incrementalInitialMarginFraction);
  }

  function loadMarketWithOverridesForWallet(
    Market memory market,
    address wallet,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet
  ) internal view returns (Market memory) {
    MarketOverrides memory marketOverrides = marketOverridesByBaseAssetSymbolAndWallet[market.baseAssetSymbol][wallet];
    if (marketOverrides.exists) {
      return
        Market({
          exists: market.exists,
          isActive: market.isActive,
          baseAssetSymbol: market.baseAssetSymbol,
          chainlinkPriceFeedAddress: market.chainlinkPriceFeedAddress,
          indexPriceAtDeactivation: market.indexPriceAtDeactivation,
          lastIndexPrice: market.lastIndexPrice,
          lastIndexPriceTimestampInMs: market.lastIndexPriceTimestampInMs,
          overridableFields: marketOverrides.overridableFields
        });
    }

    return market;
  }
}
