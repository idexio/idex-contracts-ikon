// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

import { SortedStringSet } from "../libraries/SortedStringSet.sol";

contract SortedStringSetMock {
  function indexOf(string[] memory array, string memory element) public pure returns (uint256) {
    return SortedStringSet.indexOf(array, element);
  }

  function insertSorted(string[] memory array, string memory element) public pure returns (string[] memory) {
    return SortedStringSet.insertSorted(array, element);
  }

  function merge(string[] memory array1, string[] memory array2) public pure returns (string[] memory) {
    return SortedStringSet.merge(array1, array2);
  }

  function remove(string[] memory array, string memory element) public pure returns (string[] memory) {
    return SortedStringSet.remove(array, element);
  }
}
