// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.15;

import { String } from './String.sol';

library StringArray {
  function insertSorted(string[] memory array, string memory element)
    internal
    pure
    returns (string[] memory result)
  {
    result = new string[](array.length + 1);

    bool indexFound = false;
    for (uint256 i = 0; i < result.length; i++) {
      if (!indexFound) {
        // Do not allow duplicates
        if (String.isEqual(result[i], element)) {
          return array;
        }
        if (i == result.length - 1 || isLessThan(element, array[i])) {
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

  function remove(string[] memory array, string memory element)
    internal
    pure
    returns (string[] memory result)
  {
    result = new string[](array.length - 1);

    bool indexFound = false;
    for (uint256 i = 0; i < array.length - 1; i++) {
      if (String.isEqual(array[i], element)) {
        indexFound = true;
      }
      result[i] = indexFound ? array[i + 1] : array[i];
    }
  }

  function isLessThan(string memory a, string memory b)
    private
    pure
    returns (bool)
  {
    (bytes32 aHash, bytes32 bHash) = (
      keccak256(abi.encodePacked(a)),
      keccak256(abi.encodePacked(b))
    );

    return aHash < bHash;
  }
}
