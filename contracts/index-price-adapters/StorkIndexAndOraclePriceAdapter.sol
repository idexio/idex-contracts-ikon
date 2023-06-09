// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { AssetUnitConversions } from "../libraries/AssetUnitConversions.sol";
import { Constants } from "../libraries/Constants.sol";
import { Owned } from "../Owned.sol";
import { IExchange, IIndexPriceAdapter, IOraclePriceAdapter } from "../libraries/Interfaces.sol";
import { IndexPrice, Market } from "../libraries/Structs.sol";

// https://docs.stork.network/verifying-stork-prices-on-chain/evm-verification-contract-v0
interface IStorkVerifier {
  function verifySignature(
    // solhint-disable-next-line func-param-name-mixedcase, var-name-mixedcase
    address oracle_pubkey,
    // solhint-disable-next-line func-param-name-mixedcase, var-name-mixedcase
    string memory asset_pair_id,
    uint256 timestamp,
    uint256 price,
    bytes32 r,
    bytes32 s,
    uint8 v
  ) external pure returns (bool);
}

contract StorkIndexAndOraclePriceAdapter is IIndexPriceAdapter, IOraclePriceAdapter, Owned {
  // Address whitelisted to call `setActive`
  address public immutable activator;
  // Address of Exchange contract
  IExchange public exchange;
  // Publisher wallet addresses whitelisted to sign index price payloads
  address[] public publisherWallets;
  // Mapping of base asset symbol => index price struct
  mapping(string => IndexPrice) public latestIndexPriceByBaseAssetSymbol;
  IStorkVerifier public immutable verifier;

  modifier onlyActivator() {
    require(msg.sender == activator, "Caller must be activator");
    _;
  }

  modifier onlyExchange() {
    require(_isActive(), "Exchange not set");
    require(msg.sender == address(exchange), "Caller must be Exchange contract");
    _;
  }

  /**
   * @notice Instantiate a new `StorkIndexAndOraclePriceAdapter` contract
   *
   * @param activator_ Address whitelisted to call `setActive`
   * @param publisherWallets_ Addresses of oracle publisher wallets whitelisted to sign index prices
   */
  constructor(address activator_, address[] memory publisherWallets_, IStorkVerifier verifier_) Owned() {
    require(activator_ != address(0x0), "Invalid activator address");
    activator = activator_;

    require(publisherWallets_.length > 0, "Missing publisher wallets");
    for (uint8 i = 0; i < publisherWallets_.length; i++) {
      require(publisherWallets_[i] != address(0x0), "Invalid publisher wallet");
    }
    publisherWallets = publisherWallets_;

    require(Address.isContract(address(verifier_)), "Invalid verifier address");
    verifier = verifier_;
  }

  /**
   * @notice Return latest price for base asset symbol in quote asset terms. Reverts if no price is available
   */
  function loadPriceForBaseAssetSymbol(string memory baseAssetSymbol) public view returns (uint64 price) {
    IndexPrice memory indexPrice = latestIndexPriceByBaseAssetSymbol[baseAssetSymbol];
    require(indexPrice.price > 0, "Missing price");

    return indexPrice.price;
  }

  /**
   * @notice Sets adapter as active, indicating that it is now whitelisted by the Exchange
   */
  function setActive(IExchange exchange_) public override(IIndexPriceAdapter, IOraclePriceAdapter) onlyActivator {
    if (_isActive()) {
      // When used for both oracle and index price roles, this function will validly be called twice
      return;
    }

    require(Address.isContract(address(exchange_)), "Invalid Exchange contract address");

    exchange = exchange_;

    Market memory market;
    for (uint8 i = 0; i < exchange.loadMarketsLength(); i++) {
      market = exchange.loadMarket(i);
      latestIndexPriceByBaseAssetSymbol[market.baseAssetSymbol] = IndexPrice(
        market.baseAssetSymbol,
        market.lastIndexPriceTimestampInMs,
        market.lastIndexPrice
      );
    }
  }

  /**
   * @notice Validate encoded payload and return `IndexPrice` struct
   *
   * @dev If this adapter has not yet been set active, `onlyExchange` will revert
   */
  function validateIndexPricePayload(bytes memory payload) public onlyExchange returns (IndexPrice memory) {
    IndexPrice memory indexPrice = _validateIndexPricePayload(payload);

    if (latestIndexPriceByBaseAssetSymbol[indexPrice.baseAssetSymbol].timestampInMs < indexPrice.timestampInMs) {
      latestIndexPriceByBaseAssetSymbol[indexPrice.baseAssetSymbol] = indexPrice;
    }

    return indexPrice;
  }

  /**
   * @notice Validate an encoded payload in order to set initial price for a new market
   *
   * @dev When adding a new market, `MarketAdmin` sets the initial price from the current oracle price adapter. This
   * contract sources oracle price data from index price payloads it has already seen, so to avoid reversion when
   * adding a new market an index price payload corresponding to the new market must first be provided to this function
   */
  function validateInitialIndexPricePayloadAdmin(bytes memory payload) public onlyAdmin {
    require(_isActive(), "Exchange not set");

    IndexPrice memory indexPrice = _validateIndexPricePayload(payload);

    require(
      latestIndexPriceByBaseAssetSymbol[indexPrice.baseAssetSymbol].timestampInMs == 0,
      "Price already exists for market"
    );

    latestIndexPriceByBaseAssetSymbol[indexPrice.baseAssetSymbol] = indexPrice;
  }

  function _isActive() private view returns (bool) {
    return address(exchange) != address(0x0);
  }

  function _validateIndexPricePayload(bytes memory payload) private view returns (IndexPrice memory) {
    (
      address publisherWallet,
      string memory baseAssetSymbol,
      uint256 timestamp,
      uint256 price,
      bytes32 r,
      bytes32 s,
      uint8 v
    ) = abi.decode(payload, (address, string, uint256, uint256, bytes32, bytes32, uint8));

    // Verify signer is whitelisted
    require(_isPublisherWalletValid(publisherWallet), "Invalid index price signer");

    require(price > 0, "Unexpected non-positive price");

    require(
      verifier.verifySignature(
        publisherWallet,
        string(abi.encodePacked(baseAssetSymbol, Constants.QUOTE_ASSET_SYMBOL)),
        timestamp,
        price,
        r,
        s,
        v
      ),
      "Invalid index price signature"
    );

    uint64 priceInPips = AssetUnitConversions.assetUnitsToPips(price, 18);
    require(priceInPips > 0, "Unexpected non-positive price");

    return
      IndexPrice({
        baseAssetSymbol: baseAssetSymbol,
        timestampInMs: SafeCast.toUint64(timestamp * 1000),
        price: priceInPips
      });
  }

  function _isPublisherWalletValid(address publisherWallet) private view returns (bool) {
    for (uint8 i = 0; i < publisherWallets.length; i++) {
      if (publisherWallet == publisherWallets[i]) {
        return true;
      }
    }

    return false;
  }
}
