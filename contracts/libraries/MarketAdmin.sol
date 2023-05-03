// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IPyth } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { PythStructs } from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

import { Constants } from "./Constants.sol";
import { Funding } from "./Funding.sol";
import { Hashing } from "./Hashing.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { String } from "./String.sol";
import { Time } from "./Time.sol";
import { Validations } from "./Validations.sol";
import { FundingMultiplierQuartet, IndexPrice, Market } from "./Structs.sol";

library MarketAdmin {
  using MarketHelper for Market;

  address constant _pythAddress = 0x939C0e902FF5B3F7BA666Cc8F6aC75EE76d3f900;
  bytes32 constant _pythPriceId = 0xf9c0172ba10dfa4d19088d94f5bf61d3b54d5bd7483a322a982e1373ee8ea31b; // BTC-USD

  // solhint-disable-next-line func-name-mixedcase
  function addMarket_delegatecall(
    Market memory newMarket,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    require(!marketsByBaseAssetSymbol[newMarket.baseAssetSymbol].exists, "Market already exists");
    require(
      !String.isEqual(newMarket.baseAssetSymbol, Constants.QUOTE_ASSET_SYMBOL),
      "Base asset symbol cannot be same as quote"
    );
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
    bytes32 domainSeparator,
    IndexPrice[] memory indexPrices,
    address[] memory indexPriceServiceWallets,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    Market storage market;

    for (uint8 i = 0; i < indexPrices.length; i++) {
      market = marketsByBaseAssetSymbol[indexPrices[i].baseAssetSymbol];

      require(market.exists && market.isActive, "Active market not found");
      require(market.lastIndexPriceTimestampInMs < indexPrices[i].timestampInMs, "Outdated index price");
      require(indexPrices[i].timestampInMs < Time.getOneDayFromNowInMs(), "Index price timestamp too high");
      //_validateIndexPriceSignature(domainSeparator, indexPrices[i], indexPriceServiceWallets);

      bytes[] memory updateData = new bytes[](1);
      updateData[0] = indexPrices[i].signature;

      bytes32[] memory priceIds = new bytes32[](1);
      priceIds[0] = _pythPriceId;

      uint256 fee = IPyth(_pythAddress).getUpdateFee(updateData);
      PythStructs.PriceFeed[] memory priceFeeds = IPyth(_pythAddress).parsePriceFeedUpdates{ value: fee }(
        updateData,
        priceIds,
        0,
        1693086726
      );
      // Do something with parsed structs

      market.lastIndexPrice = indexPrices[i].price;
      market.lastIndexPriceTimestampInMs = indexPrices[i].timestampInMs;
    }
  }

  function _validateIndexPriceSignature(
    bytes32 domainSeparator,
    IndexPrice memory indexPrice,
    address[] memory indexPriceServiceWallets
  ) private pure {
    bytes32 indexPriceHash = Hashing.getIndexPriceHash(indexPrice);

    address signer = Hashing.getSigner(domainSeparator, indexPriceHash, indexPrice.signature);
    bool isSignatureValid = false;
    for (uint8 i = 0; i < indexPriceServiceWallets.length; i++) {
      isSignatureValid = isSignatureValid || signer == indexPriceServiceWallets[i];
    }
    require(isSignatureValid, "Invalid index price signature");
  }
}
