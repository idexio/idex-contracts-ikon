// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IPyth, PythStructs } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";

import { Math } from "../libraries/Math.sol";
import { Owned } from "../Owned.sol";
import { String } from "../libraries/String.sol";
import { IExchange, IOraclePriceAdapter } from "../libraries/Interfaces.sol";

struct PythMarket {
  bool exists;
  string baseAssetSymbol;
  bytes32 priceId;
  uint64 priceMultiplier;
}

contract PythOraclePriceAdapter is IOraclePriceAdapter, Owned {
  // Mapping of Pyth price IDs to market structs
  mapping(bytes32 => PythMarket) public marketsByPriceId;
  // Mapping of market base asset symbols to market structs
  mapping(string => PythMarket) public marketsByBaseAssetSymbol;
  // Address of Pyth contract
  IPyth public immutable pyth;

  /**
   * @notice Instantiate a new `PythOraclePriceAdapter` contract
   *
   * @param baseAssetSymbols List of base asset symbols to associate with price IDs
   * @param priceIds List of price IDs to associate with base asset symbols
   * @param pyth_ Address of Pyth contract
   */
  constructor(
    string[] memory baseAssetSymbols,
    bytes32[] memory priceIds,
    uint64[] memory priceMultipliers,
    address pyth_
  ) Owned() {
    require(Address.isContract(pyth_), "Invalid Pyth contract address");

    pyth = IPyth(pyth_);

    require(baseAssetSymbols.length == priceIds.length, "Argument length mismatch");

    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      addMarket(baseAssetSymbols[i], priceIds[i], priceMultipliers[i]);
    }
  }

  /*
   * @notice Adds a new base asset symbol to price ID mapping for use by `loadPriceForBaseAssetSymbol`. Neither the
   * symbol nor corresponding ID can already have been added
   *
   * @param baseAssetSymbol The symbol of the base asset symbol
   * @param priceId The Pyth price feed ID
   */
  function addMarket(string memory baseAssetSymbol, bytes32 priceId, uint64 priceMultiplier) public onlyAdmin {
    require(priceId != bytes32(0x0), "Invalid price ID");
    require(!marketsByPriceId[priceId].exists, "Already added price ID");

    require(bytes(baseAssetSymbol).length > 0, "Invalid base asset symbol");
    require(!marketsByBaseAssetSymbol[baseAssetSymbol].exists, "Already added base asset symbol");

    require(priceMultiplier > 0, "Invalid price multiplier");

    if (priceMultiplier > 1) {
      string memory priceMultiplierAsString = Strings.toString(priceMultiplier);
      require(
        String.startsWith(baseAssetSymbol, priceMultiplierAsString),
        "Base asset symbol does not start with price multiplier"
      );
    }

    PythMarket memory pythMarket = PythMarket({
      exists: true,
      baseAssetSymbol: baseAssetSymbol,
      priceId: priceId,
      priceMultiplier: priceMultiplier
    });

    marketsByPriceId[priceId] = pythMarket;
    marketsByBaseAssetSymbol[baseAssetSymbol] = pythMarket;
  }

  /**
   * @notice Return latest price for base asset symbol in quote asset terms. Reverts if no price is available
   */
  function loadPriceForBaseAssetSymbol(string memory baseAssetSymbol) public view returns (uint64 price) {
    PythMarket memory market = marketsByBaseAssetSymbol[baseAssetSymbol];
    require(market.exists, "Unknown base asset symbol");

    PythStructs.Price memory pythPrice = pyth.getPriceUnsafe(market.priceId);

    uint64 priceInPips = _priceToPips(pythPrice.price, pythPrice.expo, market.priceMultiplier);
    require(priceInPips > 0, "Unexpected non-positive price");

    return SafeCast.toUint64(priceInPips);
  }

  /**
   * @notice Sets adapter as active, indicating that it is now whitelisted by the Exchange
   *
   * @dev No-op, this contract has no state to initialize on activation
   */
  function setActive(IExchange exchange_) public {}

  function _priceToPips(
    int64 price,
    int32 exponent,
    uint64 priceMultiplier
  ) internal pure returns (uint64 priceInPips) {
    require(price > 0, "Unexpected non-positive price");

    // Solidity exponents cannot be negative, so divide or multiply based on exponent signedness after pip correction
    int32 exponentCorrectedForPips = exponent + 8;
    if (exponentCorrectedForPips < 0) {
      priceInPips = (uint64(price) * priceMultiplier) / (uint64(10) ** (uint32(-1 * exponentCorrectedForPips)));
    } else {
      priceInPips = uint64(price) * priceMultiplier * (uint64(10) ** (uint32(exponentCorrectedForPips)));
    }
  }
}
