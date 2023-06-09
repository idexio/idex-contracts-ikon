// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IPyth, PythStructs } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";

import { IndexPrice } from "../libraries/Structs.sol";
import { Owned } from "../Owned.sol";
import { PythOraclePriceAdapter } from "../oracle-price-adapters/PythOraclePriceAdapter.sol";
import { Time } from "../libraries/Time.sol";
import { IExchange, IIndexPriceAdapter } from "../libraries/Interfaces.sol";

contract PythIndexPriceAdapter is IIndexPriceAdapter, Owned {
  // Address whitelisted to call `setActive`
  address public immutable activator;
  // Mapping of Pyth price IDs to market base asset symbols
  mapping(bytes32 => string) public baseAssetSymbolsByPriceId;
  // Address of Exchange contract
  IExchange public exchange;
  // Mapping of market base asset symbols to Pyth price IDs
  mapping(string => bytes32) public priceIdsByBaseAssetSymbol;
  // Address of Pyth contract
  IPyth public immutable pyth;

  /**
   * @notice Instantiate a new `PythIndexPriceAdapter` contract
   *
   * @param activator_ Address whitelisted to call `setActive`
   * @param baseAssetSymbols List of base asset symbols to associate with price IDs
   * @param priceIds List of price IDs to associate with base asset symbols
   * @param pyth_ Address of Pyth contract
   */
  constructor(address activator_, string[] memory baseAssetSymbols, bytes32[] memory priceIds, address pyth_) Owned() {
    require(activator_ != address(0x0), "Invalid activator address");
    activator = activator_;

    require(baseAssetSymbols.length == priceIds.length, "Argument length mismatch");

    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      require(bytes(baseAssetSymbols[i]).length > 0, "Invalid base asset symbol");
      require(priceIds[i] != bytes32(0x0), "Invalid price ID");

      baseAssetSymbolsByPriceId[priceIds[i]] = baseAssetSymbols[i];
      priceIdsByBaseAssetSymbol[baseAssetSymbols[i]] = priceIds[i];
    }

    require(Address.isContract(pyth_), "Invalid Pyth contract address");
    pyth = IPyth(pyth_);
  }

  /**
   * @notice Allow incoming native asset to fund contract for network update fees
   */
  receive() external payable {}

  modifier onlyActivator() {
    require(msg.sender == activator, "Caller must be activator");
    _;
  }

  modifier onlyExchange() {
    require(msg.sender == address(exchange), "Caller must be Exchange contract");
    _;
  }

  /*
   * @notice Adds a new price ID to base asset symbol mapping for use by `validateIndexPricePayload`. Neither the
   * symbol nor corresponding ID can already have been added
   *
   * @param baseAssetSymbol The symbol of the base asset symbol
   * @param priceId The Pyth price feed ID
   */
  function addBaseAssetSymbolAndPriceId(string memory baseAssetSymbol, bytes32 priceId) public onlyAdmin {
    require(priceId != bytes32(0x0), "Invalid price ID");
    require(bytes(baseAssetSymbolsByPriceId[priceId]).length == 0, "Already added price ID");

    require(bytes(baseAssetSymbol).length > 0, "Invalid base asset symbol");
    require(priceIdsByBaseAssetSymbol[baseAssetSymbol] == bytes32(0x0), "Already added base asset symbol");

    baseAssetSymbolsByPriceId[priceId] = baseAssetSymbol;
    priceIdsByBaseAssetSymbol[baseAssetSymbol] = priceId;
  }

  /**
   * @notice Sets adapter as active, indicating that it is now whitelisted by the Exchange
   */
  function setActive(IExchange exchange_) public onlyActivator {
    require(!_isActive(), "Adapter already active");

    require(Address.isContract(address(exchange_)), "Invalid Exchange contract address");

    exchange = exchange_;
  }

  /**
   * @notice Validate encoded payload and return `IndexPrice` struct
   */
  function validateIndexPricePayload(bytes memory payload) public onlyExchange returns (IndexPrice memory) {
    (bytes32 priceId, bytes memory encodedPrice) = abi.decode(payload, (bytes32, bytes));

    bytes[] memory updateData = new bytes[](1);
    updateData[0] = encodedPrice;

    bytes32[] memory priceIds = new bytes32[](1);
    priceIds[0] = priceId;

    uint256 fee = pyth.getUpdateFee(updateData);
    require(address(this).balance >= fee, "Insufficient balance for update fee");

    PythStructs.PriceFeed[] memory priceFeeds = pyth.parsePriceFeedUpdates{ value: fee }(
      updateData,
      priceIds,
      0,
      Time.getOneDayFromNowInS()
    );

    string memory baseAssetSymbol = baseAssetSymbolsByPriceId[priceId];
    require(bytes(baseAssetSymbol).length > 0, "Unknown price ID");

    uint64 priceInPips = _priceToPips(priceFeeds[0].price.price, priceFeeds[0].price.expo);
    require(priceInPips > 0, "Unexpected non-positive price");

    return
      IndexPrice({
        baseAssetSymbol: baseAssetSymbol,
        timestampInMs: SafeCast.toUint64(priceFeeds[0].price.publishTime * 1000),
        price: priceInPips
      });
  }

  /**
   * @notice Allow Admin wallet to withdraw network update fee funding
   */
  function withdrawNativeAsset(address payable destinationWallet, uint256 quantity) public onlyAdmin {
    destinationWallet.transfer(quantity);
  }

  function _isActive() private view returns (bool) {
    return address(exchange) != address(0x0);
  }

  function _priceToPips(int64 price, int32 exponent) internal pure returns (uint64 priceInPips) {
    require(price > 0, "Unexpected non-positive price");

    // Solidity exponents cannot be negative, so divide or multiply based on exponent signedness after pip correction
    int32 exponentCorrectedForPips = exponent + 8;
    if (exponentCorrectedForPips < 0) {
      priceInPips = uint64(price) / (uint64(10) ** (uint32(-1 * exponentCorrectedForPips)));
    } else {
      priceInPips = uint64(price) * (uint64(10) ** (uint32(exponentCorrectedForPips)));
    }
  }
}