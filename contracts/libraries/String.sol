// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { Constants } from "./Constants.sol";

library String {
  // See https://solidity.readthedocs.io/en/latest/types.html#bytes-and-strings-as-arrays
  function isEqual(string memory a, string memory b) internal pure returns (bool) {
    return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
  }

  function startsWith(string memory self, string memory prefix) internal pure returns (bool) {
    uint256 prefixLength = bytes(prefix).length;
    if (bytes(self).length < bytes(prefix).length) {
      return false;
    }

    bytes memory selfPrefix = new bytes(prefixLength);
    for (uint i = 0; i < prefixLength; i++) {
      selfPrefix[i] = bytes(self)[i];
    }

    return isEqual(string(selfPrefix), prefix);
  }

  /**
   * @dev Converts an integer pip quantity back into the fixed-precision decimal pip string
   * originally signed by the wallet. For example, 1234567890 becomes '12.34567890'
   */
  function pipsToDecimalString(uint64 pips) internal pure returns (string memory) {
    if (pips == 0) {
      return Constants.EMPTY_DECIMAL_STRING;
    }

    // Inspired by https://github.com/provable-things/ethereum-api/blob/831f4123816f7a3e57ebea171a3cdcf3b528e475/oraclizeAPI_0.5.sol#L1045-L1062
    uint256 copy = pips;
    uint256 length;
    while (copy != 0) {
      length++;
      copy /= 10;
    }
    if (length < 9) {
      length = 9; // a zero before the decimal point plus 8 decimals
    }
    length++; // for the decimal point

    bytes memory decimal = new bytes(length);
    for (uint256 i = length; i > 0; i--) {
      if (length - i == 8) {
        decimal[i - 1] = bytes1(uint8(46)); // period
      } else {
        decimal[i - 1] = bytes1(uint8(48 + (pips % 10)));
        pips /= 10;
      }
    }
    return string(decimal);
  }
}
