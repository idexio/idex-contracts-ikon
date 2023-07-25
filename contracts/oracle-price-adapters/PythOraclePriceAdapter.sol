// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IPyth, PythStructs } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";

import { Math } from "../libraries/Math.sol";
import { Owned } from "../Owned.sol";
import { IExchange, IOraclePriceAdapter } from "../libraries/Interfaces.sol";

contract PythOraclePriceAdapter is IOraclePriceAdapter, Owned {
  // Mapping of Pyth price IDs to market base asset symbols
  mapping(bytes32 => string) public baseAssetSymbolsByPriceId;
  // Mapping of market base asset symbols to Pyth price IDs
  mapping(string => bytes32) public priceIdsByBaseAssetSymbol;
  // Address of Pyth contract
  IPyth public immutable pyth;

  /**
   * @notice Instantiate a new `PythOraclePriceAdapter` contract
   *
   * @param baseAssetSymbols List of base asset symbols to associate with price IDs
   * @param priceIds List of price IDs to associate with base asset symbols
   * @param pyth_ Address of Pyth contract
   */
  constructor(string[] memory baseAssetSymbols, bytes32[] memory priceIds, address pyth_) Owned() {
    require(Address.isContract(pyth_), "Invalid Pyth contract address");

    pyth = IPyth(pyth_);

    require(baseAssetSymbols.length == priceIds.length, "Argument length mismatch");

    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      require(bytes(baseAssetSymbols[i]).length > 0, "Invalid base asset symbol");
      require(priceIds[i] != bytes32(0x0), "Invalid price ID");

      baseAssetSymbolsByPriceId[priceIds[i]] = baseAssetSymbols[i];
      priceIdsByBaseAssetSymbol[baseAssetSymbols[i]] = priceIds[i];
    }
  }

  /*
   * @notice Adds a new base asset symbol to price ID mapping for use by `loadPriceForBaseAssetSymbol`. Neither the
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
   * @notice Return latest price for base asset symbol in quote asset terms. Reverts if no price is available
   */
  function loadPriceForBaseAssetSymbol(string memory baseAssetSymbol) public view returns (uint64 price) {
    bytes32 priceId = priceIdsByBaseAssetSymbol[baseAssetSymbol];
    require(priceId != bytes32(0x0), "Invalid base asset symbol");

    PythStructs.Price memory pythPrice = pyth.getPrice(priceId);

    uint64 priceInPips = _priceToPips(pythPrice.price, pythPrice.expo);
    require(priceInPips > 0, "Unexpected non-positive price");

    return priceInPips;
  }

  /**
   * @notice Sets adapter as active, indicating that it is now whitelisted by the Exchange
   *
   * @dev No-op, this contract has no state to initialize on activation
   */
  function setActive(IExchange exchange_) public {}

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
