// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.8.18;

library String {
  // See https://solidity.readthedocs.io/en/latest/types.html#bytes-and-strings-as-arrays
  function isEqual(string memory a, string memory b)
    internal
    pure
    returns (bool)
  {
    return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
  }
}
