// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { FieldUpgradeGovernance } from "./FieldUpgradeGovernance.sol";
import { Funding } from "./Funding.sol";
import { Hashing } from "./Hashing.sol";
import { MarketHelper } from "./MarketHelper.sol";
import { Time } from "./Time.sol";
import { FundingMultiplierQuartet, IndexPrice, Market, MarketOverrides, OverridableMarketFields } from "./Structs.sol";

library MarketAdmin {
  using FieldUpgradeGovernance for FieldUpgradeGovernance.Storage;
  using MarketHelper for Market;

  // 0.005
  uint64 private constant _MIN_INITIAL_MARGIN_FRACTION = 500000;
  // 0.003
  uint64 private constant _MIN_MAINTENANCE_MARGIN_FRACTION = 300000;
  // 0.001
  uint64 private constant _MIN_INCREMENTAL_INITIAL_MARGIN_FRACTION = 100000;
  // Max int64
  uint64 private constant _MAX_MAXIMUM_POSITION_SIZE = 2 ** 63 - 1;
  // Max int64 - 1
  uint64 private constant _MAX_MINIMUM_POSITION_SIZE = 2 ** 63 - 2;

  // solhint-disable-next-line func-name-mixedcase
  function addMarket_delegatecall(
    Market memory newMarket,
    mapping(string => FundingMultiplierQuartet[]) storage fundingMultipliersByBaseAssetSymbol,
    mapping(string => uint64) storage lastFundingRatePublishTimestampInMsByBaseAssetSymbol,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    require(!marketsByBaseAssetSymbol[newMarket.baseAssetSymbol].exists, "Market already exists");
    require(Address.isContract(address(newMarket.chainlinkPriceFeedAddress)), "Invalid Chainlink price feed");
    _validateOverridableMarketFields(newMarket.overridableFields);

    // Populate non-overridable fields and commit new market to storage
    newMarket.exists = true;
    newMarket.isActive = false;
    newMarket.lastIndexPrice = newMarket.loadOnChainFeedPrice();
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
    require(market.exists && !market.isActive, "No deactived market found");

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
    address[] memory indexPriceCollectionServiceWallets,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    Market storage market;

    for (uint8 i = 0; i < indexPrices.length; i++) {
      market = marketsByBaseAssetSymbol[indexPrices[i].baseAssetSymbol];
      require(market.exists && market.isActive, "Active market not found");

      _validateIndexPrice(indexPrices[i], indexPriceCollectionServiceWallets, market);

      market.lastIndexPrice = indexPrices[i].price;
      market.lastIndexPriceTimestampInMs = indexPrices[i].timestampInMs;
    }
  }

  // solhint-disable-next-line func-name-mixedcase
  function initiateMarketOverridesUpgrade_delegatecall(
    string memory baseAssetSymbol,
    OverridableMarketFields memory overridableFields,
    address wallet,
    FieldUpgradeGovernance.Storage storage fieldUpgradeGovernance,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public returns (uint256 blockThreshold) {
    require(marketsByBaseAssetSymbol[baseAssetSymbol].exists, "Market does not exist");
    _validateOverridableMarketFields(overridableFields);

    blockThreshold = fieldUpgradeGovernance.initiateMarketOverridesUpgrade(baseAssetSymbol, overridableFields, wallet);
  }

  // solhint-disable-next-line func-name-mixedcase
  function cancelMarketOverridesUpgrade_delegatecall(
    string memory baseAssetSymbol,
    address wallet,
    FieldUpgradeGovernance.Storage storage fieldUpgradeGovernance
  ) public {
    fieldUpgradeGovernance.cancelMarketOverridesUpgrade(baseAssetSymbol, wallet);
  }

  // solhint-disable-next-line func-name-mixedcase
  function finalizeMarketOverridesUpgrade_delegatecall(
    string memory baseAssetSymbol,
    address wallet,
    FieldUpgradeGovernance.Storage storage fieldUpgradeGovernance,
    mapping(string => mapping(address => MarketOverrides)) storage marketOverridesByBaseAssetSymbolAndWallet,
    mapping(string => Market) storage marketsByBaseAssetSymbol
  ) public {
    OverridableMarketFields memory marketOverrides = fieldUpgradeGovernance.finalizeMarketOverridesUpgrade(
      baseAssetSymbol,
      wallet
    );

    if (wallet == address(0x0)) {
      marketsByBaseAssetSymbol[baseAssetSymbol].overridableFields = marketOverrides;
    } else {
      marketOverridesByBaseAssetSymbolAndWallet[baseAssetSymbol][wallet] = MarketOverrides({
        exists: true,
        overridableFields: marketOverrides
      });
    }
  }

  // Validate reasonable limits on overridable market fields
  function _validateOverridableMarketFields(OverridableMarketFields memory overridableFields) private pure {
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
      overridableFields.baselinePositionSize <= overridableFields.maximumPositionSize,
      "Baseline position size exceeds maximum"
    );
    require(overridableFields.maximumPositionSize <= _MAX_MAXIMUM_POSITION_SIZE, "Maximum position size exceeds max");
    require(overridableFields.minimumPositionSize <= _MAX_MINIMUM_POSITION_SIZE, "Minimum position size exceeds max");
  }

  function _validateIndexPrice(
    IndexPrice memory indexPrice,
    address[] memory indexPriceCollectionServiceWallets,
    Market memory market
  ) private view {
    require(market.lastIndexPriceTimestampInMs < indexPrice.timestampInMs, "Outdated index price");

    require(indexPrice.timestampInMs < Time.getOneDayFromNowInMs(), "Index price timestamp too high");

    _validateIndexPriceSignature(indexPrice, indexPriceCollectionServiceWallets);
  }

  function _validateIndexPriceSignature(
    IndexPrice memory indexPrice,
    address[] memory indexPriceCollectionServiceWallets
  ) private pure {
    bytes32 indexPriceHash = Hashing.getIndexPriceHash(indexPrice);

    address signer = Hashing.getSigner(indexPriceHash, indexPrice.signature);
    bool isSignatureValid = false;
    for (uint8 i = 0; i < indexPriceCollectionServiceWallets.length; i++) {
      isSignatureValid = isSignatureValid || signer == indexPriceCollectionServiceWallets[i];
    }
    require(isSignatureValid, "Invalid index signature");
  }
}
