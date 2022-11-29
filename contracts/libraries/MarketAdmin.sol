// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.17;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { Validations } from "./Validations.sol";
import { Market, OraclePrice } from "./Structs.sol";

library MarketAdmin {
  // TODO Validations
  function addMarket(Market memory newMarket, mapping(string => Market) storage marketsByBaseAssetSymbol) public {
    require(!marketsByBaseAssetSymbol[newMarket.baseAssetSymbol].exists, "Market already exists");

    require(Address.isContract(address(newMarket.chainlinkPriceFeedAddress)), "Invalid Chainlink price feed");

    newMarket.exists = true;
    newMarket.isActive = false;
    newMarket.lastOraclePriceTimestampInMs = 0;
    newMarket.oraclePriceInPipsAtDeactivation = 0;

    marketsByBaseAssetSymbol[newMarket.baseAssetSymbol] = newMarket;
  }

  function activateMarket(
    string calldata baseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    Market storage market = marketsByBaseAssetSymbol[baseAssetSymbol];
    require(market.exists && !market.isActive, "No deactived market found");

    market.isActive = true;
    market.oraclePriceInPipsAtDeactivation = 0;
  }

  function deactivateMarket(
    string calldata baseAssetSymbol,
    OraclePrice memory oraclePrice,
    address oracleWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    Market storage market = marketsByBaseAssetSymbol[baseAssetSymbol];
    require(market.exists && market.isActive, "No active market found");

    uint64 oraclePriceInPips = Validations.validateAndUpdateOraclePriceAndConvertToPips(
      market,
      oraclePrice,
      oracleWallet
    );

    market.isActive = false;
    market.oraclePriceInPipsAtDeactivation = oraclePriceInPips;
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
    marketOverrides.lastOraclePriceTimestampInMs = 0;
    marketOverrides.oraclePriceInPipsAtDeactivation = 0;

    marketOverridesByBaseAssetSymbolAndWallet[marketOverrides.baseAssetSymbol][wallet] = marketOverrides;
  }
}
