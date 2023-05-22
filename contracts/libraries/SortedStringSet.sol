// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { String } from "./String.sol";

library SortedStringSet {
  uint256 public constant NOT_FOUND = type(uint256).max;

  function indexOf(string[] memory array, string memory element) internal pure returns (uint256) {
    for (uint256 i = 0; i < array.length; i++) {
      if (String.isEqual(array[i], element)) {
        return i;
      }
    }

    return NOT_FOUND;
  }

  function insertSorted(string[] memory array, string memory element) internal pure returns (string[] memory result) {
    result = new string[](array.length + 1);

    bool indexFound = false;
    for (uint256 i = 0; i < result.length; i++) {
      if (!indexFound) {
        // Do not allow duplicates
        if (i < result.length - 1 && String.isEqual(array[i], element)) {
          return array;
        }
        if (i == result.length - 1 || _isLessThan(element, array[i])) {
          result[i] = element;
          indexFound = true;
        } else {
          result[i] = array[i];
        }
      } else {
        result[i] = array[i - 1];
      }
    }
  }

  function merge(string[] memory array1, string[] memory array2) internal pure returns (string[] memory result) {
    result = array1;

    for (uint256 i = 0; i < array2.length; i++) {
      result = insertSorted(result, array2[i]);
    }
  }

  function remove(string[] memory array, string memory element) internal pure returns (string[] memory result) {
    result = new string[](array.length - 1);

    bool indexFound = false;
    for (uint256 i = 0; i < array.length - 1; i++) {
      if (String.isEqual(array[i], element)) {
        indexFound = true;
      }
      result[i] = indexFound ? array[i + 1] : array[i];
    }

    require(indexFound || String.isEqual(array[array.length - 1], element), "Element to remove not found");
  }

  function _isLessThan(string memory a, string memory b) private pure returns (bool) {
    (bytes32 aHash, bytes32 bHash) = (keccak256(abi.encodePacked(a)), keccak256(abi.encodePacked(b)));

    return aHash < bHash;
  }
}
