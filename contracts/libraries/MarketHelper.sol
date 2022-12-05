// SPDX-License-Identifier: LGPL-3.0-only

import { AssetUnitConversions } from "./AssetUnitConversions.sol";
import { Market } from "./Structs.sol";

pragma solidity 0.8.17;

library MarketHelper {
  function loadFeedPrice(Market memory self) internal view returns (uint64 price) {
    (, int256 answer, , , ) = self.chainlinkPriceFeedAddress.latestRoundData();
    require(answer > 0, "Unexpected non-positive feed price");

    return AssetUnitConversions.assetUnitsToPips(uint256(answer), self.chainlinkPriceFeedAddress.decimals());
  }
}
