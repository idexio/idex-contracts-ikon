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
  // Mapping of market base asset symbols to Pyth price IDs
  mapping(bytes32 => string) public baseAssetSymbolsByPriceId;
  // Address of Pyth contract
  IPyth public immutable pyth;

  // Address of Exchange contract
  IExchange public exchange;

  constructor(address pyth_, string[] memory baseAssetSymbols, bytes32[] memory priceIds) {
    require(Address.isContract(pyth_), "Invalid Pyth contract address");

    pyth = IPyth(pyth_);

    require(baseAssetSymbols.length == priceIds.length, "Argument length mismatch");

    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      require(priceIds[i] != bytes32(0x0), "Invalid price ID");
      baseAssetSymbolsByPriceId[priceIds[i]] = baseAssetSymbols[i];
    }
  }

  /**
   * @notice Allow incoming native asset to fund contract for network update fees
   */
  receive() external payable {}

  modifier onlyExchange() {
    require(msg.sender == address(exchange), "Caller must be Exchange contract");
    _;
  }

  /**
   * @notice Sets adapter as active, indicating that it is now whitelisted by the Exchange
   */
  function setActive(IExchange exchange_) public {
    require(!_isActive(), "Adapter already active");

    require(Address.isContract(address(exchange_)), "Invalid Exchange contract address");

    exchange = exchange_;
  }

  /**
   * @notice Validate encoded payload and return decoded `IndexPrice` struct
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
      Time.getOneDayFromNow()
    );

    string memory baseAssetSymbol = baseAssetSymbolsByPriceId[priceId];
    require(bytes(baseAssetSymbol).length > 0, "Invalid priceId");

    return
      IndexPrice({
        baseAssetSymbol: baseAssetSymbolsByPriceId[priceId],
        timestampInMs: SafeCast.toUint64(priceFeeds[0].price.publishTime * 1000),
        price: _priceToPips(priceFeeds[0].price.price, priceFeeds[0].price.expo)
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
