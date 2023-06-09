// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

// https://docs.stork.network/verifying-stork-prices-on-chain/evm-verification-contract-v0
contract StorkVerifierMock {
  function verifySignature(
    // solhint-disable-next-line func-param-name-mixedcase, var-name-mixedcase
    address oracle_pubkey,
    // solhint-disable-next-line func-param-name-mixedcase, var-name-mixedcase
    string memory asset_pair_id,
    uint256 timestamp,
    uint256 price,
    bytes32 r,
    bytes32 s,
    uint8 v
  ) public pure returns (bool) {
    // solhint-disable-next-line var-name-mixedcase
    bytes32 msg_hash = _getMessageHash(oracle_pubkey, asset_pair_id, timestamp, price);
    // solhint-disable-next-line var-name-mixedcase
    bytes32 signed_message_hash = _getEthSignedMessageHash32(msg_hash);

    // Verify hash was generated by the actual user
    address signer = _getSigner(signed_message_hash, r, s, v);
    return (signer == oracle_pubkey) ? true : false;
  }

  function _getEthSignedMessageHash32(bytes32 message) private pure returns (bytes32) {
    return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", message));
  }

  function _getMessageHash(
    // solhint-disable-next-line func-param-name-mixedcase, var-name-mixedcase
    address oracle_name,
    // solhint-disable-next-line func-param-name-mixedcase, var-name-mixedcase
    string memory asset_pair_id,
    uint256 timestamp,
    uint256 price
  ) private pure returns (bytes32) {
    // solhint-disable-next-line var-name-mixedcase
    return keccak256(abi.encodePacked(oracle_name, asset_pair_id, timestamp, price));
  }

  // solhint-disable-next-line func-param-name-mixedcase, var-name-mixedcase
  function _getSigner(bytes32 signed_message_hash, bytes32 r, bytes32 s, uint8 v) private pure returns (address) {
    // solhint-disable-next-line var-name-mixedcase
    return ecrecover(signed_message_hash, v, r, s);
  }
}
