// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { Validations } from "./Validations.sol";
import { Market, IndexPrice } from "./Structs.sol";

library MarketAdmin {
  // TODO Validations
  function addMarket(Market memory newMarket, mapping(string => Market) storage marketsByBaseAssetSymbol) public {
    require(!marketsByBaseAssetSymbol[newMarket.baseAssetSymbol].exists, "Market already exists");

    require(Address.isContract(address(newMarket.chainlinkPriceFeedAddress)), "Invalid Chainlink price feed");

    newMarket.exists = true;
    newMarket.isActive = false;
    newMarket.lastIndexPriceTimestampInMs = 0;
    newMarket.indexPriceAtDeactivation = 0;

    marketsByBaseAssetSymbol[newMarket.baseAssetSymbol] = newMarket;
  }

  function activateMarket(
    string calldata baseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    Market storage market = marketsByBaseAssetSymbol[baseAssetSymbol];
    require(market.exists && !market.isActive, "No deactived market found");

    market.isActive = true;
    market.indexPriceAtDeactivation = 0;
  }

  function deactivateMarket(
    string calldata baseAssetSymbol,
    IndexPrice memory indexPrice,
    address[] memory indexPriceCollectionServiceWallets,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    Market storage market = marketsByBaseAssetSymbol[baseAssetSymbol];
    require(market.exists && market.isActive, "No active market found");

    Validations.validateAndUpdateIndexPrice(indexPrice, market, indexPriceCollectionServiceWallets);

    market.isActive = false;
    market.indexPriceAtDeactivation = indexPrice.price;
  }

  // TODO Validations
  function setMarketOverrides(
    address wallet,
    Market memory marketOverrides,
    mapping(string => mapping(address => Market)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) external {
    require(marketsByBaseAssetSymbol[marketOverrides.baseAssetSymbol].exists, "Market does not exist");

    marketOverrides.isActive = marketsByBaseAssetSymbol[marketOverrides.baseAssetSymbol].isActive;
    marketOverrides.lastIndexPriceTimestampInMs = 0;
    marketOverrides.indexPriceAtDeactivation = 0;

    marketOverridesByBaseAssetSymbolAndWallet[marketOverrides.baseAssetSymbol][wallet] = marketOverrides;
  }
}
