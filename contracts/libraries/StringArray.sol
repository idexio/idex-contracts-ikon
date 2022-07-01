// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.15;

library String {
  function sort(string[] memory array) internal pure returns (string[] memory) {
    quickSort(array, 0, array.length - 1);

    return array;
  }

  function insertSorted(string[] memory array, string memory element)
    internal
    pure
    returns (string[] memory result)
  {
    result = new string[](array.length + 1);

    bool indexFound = false;
    for (uint256 i = 0; i < result.length; i++) {
      if (!indexFound) {
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

  function remove(string[] memory array, uint256 indexToRemove)
    internal
    pure
    returns (string[] memory result)
  {
    result = new string[](array.length - 1);

    for (uint256 i = 0; i < array.length - 1; i++) {
      result[i] = i >= indexToRemove ? array[i + 1] : array[i];
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

  // See https://ethereum.stackexchange.com/questions/1517/sorting-an-array-of-integer-with-ethereum#answer-1518
  function quickSort(
    string[] memory array,
    uint256 left,
    uint256 right
  ) private pure {
    // Handles common case of single element in addition to recursive base case
    if (left == right) {
      return;
    }

    string memory pivot = array[left + (right - left) / 2];
    (uint256 i, uint256 j) = (left, right);

    while (i <= j) {
      while (isLessThan(array[i], pivot)) i++;
      while (isLessThan(pivot, array[j])) j--;

      if (i <= j) {
        (array[i], array[j]) = (array[j], array[i]);

        i++;
        if (j > 0) j--;
      }
    }

    if (left < j) quickSort(array, left, j);
    if (i < right) quickSort(array, i, right);
  }
}
