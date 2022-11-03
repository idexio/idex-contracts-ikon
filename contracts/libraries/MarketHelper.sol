// SPDX-License-Identifier: LGPL-3.0-only

import { AssetUnitConversions } from './AssetUnitConversions.sol';
import { Math } from './Math.sol';
import { Market } from './Structs.sol';

pragma solidity 0.8.17;

library MarketHelper {
  function loadFeedPriceInPips(Market memory self)
    internal
    view
    returns (uint64 priceInPips)
  {
    (, int256 answer, , , ) = self.chainlinkPriceFeedAddress.latestRoundData();
    require(answer > 0, 'Unexpected non-positive feed price');

    return
      AssetUnitConversions.assetUnitsToPips(
        uint256(answer),
        self.chainlinkPriceFeedAddress.decimals()
      );
  }
}
