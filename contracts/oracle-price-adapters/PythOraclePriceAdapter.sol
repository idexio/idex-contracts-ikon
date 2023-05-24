// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IPyth, PythStructs } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";

import { Math } from "../libraries/Math.sol";
import { Owned } from "../Owned.sol";
import { IExchange, IOraclePriceAdapter } from "../libraries/Interfaces.sol";

contract PythOraclePriceAdapter is IOraclePriceAdapter, Owned {
  // Mapping of Pyth price IDs to market base asset symbols
  mapping(string => bytes32) public priceIdsByBaseAssetSymbol;
  // Address of Pyth contract
  IPyth public immutable pyth;

  constructor(address pyth_, string[] memory baseAssetSymbols, bytes32[] memory priceIds) Owned() {
    require(Address.isContract(pyth_), "Invalid Pyth contract address");

    pyth = IPyth(pyth_);

    require(baseAssetSymbols.length == priceIds.length, "Argument length mismatch");

    for (uint8 i = 0; i < baseAssetSymbols.length; i++) {
      require(priceIds[i] != bytes32(0x0), "Invalid price ID");
      priceIdsByBaseAssetSymbol[baseAssetSymbols[i]] = priceIds[i];
    }
  }

  /**
   * @notice Return latest price for base asset symbol in quote asset terms. Reverts if no price is available
   */
  function loadPriceForBaseAssetSymbol(string memory baseAssetSymbol) public view returns (uint64 price) {
    bytes32 priceId = priceIdsByBaseAssetSymbol[baseAssetSymbol];
    require(priceId != bytes32(0x0), "Invalid base asset symbol");

    PythStructs.Price memory pythPrice = pyth.getPrice(priceId);

    return _priceToPips(pythPrice.price, pythPrice.expo);
  }

  /**
   * @notice Sets adapter as active, indicating that it is now whitelisted by the Exchange
   *
   * @dev No-op
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
