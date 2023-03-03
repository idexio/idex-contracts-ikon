// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { Funding } from "./Funding.sol";
import { Hashing } from "./Hashing.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Time } from "./Time.sol";
import { Validations } from "./Validations.sol";
import { FundingMultiplierQuartet, IndexPrice, Market } from "./Structs.sol";

library MarketAdmin {
  using MarketHelper for Market;

  // solhint-disable-next-line func-name-mixedcase
  function addMarket_delegatecall(
    Market memory newMarket,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    require(!marketsByBaseAssetSymbol[newMarket.baseAssetSymbol].exists, "Market already exists");
    require(Address.isContract(address(newMarket.chainlinkPriceFeedAddress)), "Invalid Chainlink price feed");
    Validations.validateOverridableMarketFields(newMarket.overridableFields);

    // Populate non-overridable fields and commit new market to storage
    newMarket.exists = true;
    newMarket.isActive = false;
    newMarket.lastIndexPrice = newMarket.loadOraclePrice();
    newMarket.lastIndexPriceTimestampInMs = uint64(block.timestamp * 1000);
    marketsByBaseAssetSymbol[newMarket.baseAssetSymbol] = newMarket;

    Funding.backfillFundingMultipliersForMarket(
      newMarket,
      fundingMultipliersByBaseAssetSymbol,
      lastFundingRatePublishTimestampInMsByBaseAssetSymbol
    );
  }

  // solhint-disable-next-line func-name-mixedcase
  function activateMarket_delegatecall(
    string calldata baseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    Market storage market = marketsByBaseAssetSymbol[baseAssetSymbol];
    require(market.exists && !market.isActive, "No inactive market found");

    market.isActive = true;
    market.indexPriceAtDeactivation = 0;
  }

  // solhint-disable-next-line func-name-mixedcase
  function deactivateMarket_delegatecall(
    string calldata baseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    Market storage market = marketsByBaseAssetSymbol[baseAssetSymbol];
    require(market.exists && market.isActive, "No active market found");

    market.isActive = false;
    market.indexPriceAtDeactivation = market.lastIndexPrice;
  }

  // solhint-disable-next-line func-name-mixedcase
  function publishIndexPrices_delegatecall(
    IndexPrice[] memory indexPrices,
    address[] memory indexPriceServiceWallets,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    Market storage market;

    for (uint8 i = 0; i < indexPrices.length; i++) {
      market = marketsByBaseAssetSymbol[indexPrices[i].baseAssetSymbol];
      require(market.exists && market.isActive, "Active market not found");

      _validateIndexPrice(indexPrices[i], indexPriceServiceWallets, market);

      market.lastIndexPrice = indexPrices[i].price;
      market.lastIndexPriceTimestampInMs = indexPrices[i].timestampInMs;
    }
  }

  function _validateIndexPrice(
    IndexPrice memory indexPrice,
    address[] memory indexPriceServiceWallets,
    Market memory market
  ) private view {
    require(market.lastIndexPriceTimestampInMs < indexPrice.timestampInMs, "Outdated index price");

    require(indexPrice.timestampInMs < Time.getOneDayFromNowInMs(), "Index price timestamp too high");

    _validateIndexPriceSignature(indexPrice, indexPriceServiceWallets);
  }

  function _validateIndexPriceSignature(
    IndexPrice memory indexPrice,
    address[] memory indexPriceServiceWallets
  ) private pure {
    bytes32 indexPriceHash = Hashing.getIndexPriceHash(indexPrice);

    address signer = Hashing.getSigner(indexPriceHash, indexPrice.signature);
    bool isSignatureValid = false;
    for (uint8 i = 0; i < indexPriceServiceWallets.length; i++) {
      isSignatureValid = isSignatureValid || signer == indexPriceServiceWallets[i];
    }
    require(isSignatureValid, "Invalid index price signature");
  }
}
