// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import { NonceInvalidation } from "./Structs.sol";
import { Time } from "./Time.sol";
import { UUID } from "./UUID.sol";

library NonceInvalidations {
  function invalidateNonce(
    mapping(address => NonceInvalidation[]) storage self,
    uint128 nonce,
    uint256 chainPropagationPeriodInS
  ) external returns (uint64 timestampInMs, uint256 effectiveBlockTimestamp) {
    timestampInMs = UUID.getTimestampInMsFromUuidV1(nonce);
    // Enforce a maximum skew for invalidating nonce timestamps in the future so the user doesn't
    // lock their wallet from trades indefinitely
    require(timestampInMs < Time.getOneDayFromNowInMs(), "Nonce timestamp too high");

    if (self[msg.sender].length > 0) {
      NonceInvalidation storage lastInvalidation = self[msg.sender][self[msg.sender].length - 1];
      require(lastInvalidation.timestampInMs < timestampInMs, "Nonce timestamp invalidated");
      require(lastInvalidation.effectiveBlockTimestamp <= block.timestamp, "Last invalidation not finalized");
    }

    // Changing the Chain Propagation Period will not affect the effectiveBlockTimestamp for this invalidation
    effectiveBlockTimestamp = block.timestamp + chainPropagationPeriodInS;
    self[msg.sender].push(NonceInvalidation(timestampInMs, effectiveBlockTimestamp));
  }

  function loadLastInvalidatedTimestamp(
    mapping(address => NonceInvalidation[]) storage self,
    address wallet
  ) internal view returns (uint64) {
    NonceInvalidation[] storage nonceInvalidations = self[wallet];
    if (nonceInvalidations.length > 0) {
      NonceInvalidation storage lastInvalidation = self[wallet][nonceInvalidations.length - 1];
      // If the latest invalidation has gone into effect, use its timestamp
      if (lastInvalidation.effectiveBlockTimestamp <= block.timestamp) {
        return lastInvalidation.timestampInMs;
      }
      // If the latest invalidation is still pending the Chain Propagation Period, then use the timestamp of the
      // invalidation preceding it
      if (nonceInvalidations.length > 1) {
        NonceInvalidation storage nextToLastInvalidation = self[wallet][nonceInvalidations.length - 2];
        // Validation in `invalidateNonce` prohibits invalidating a nonce while a previous nonce invalidation is still
        // pending, so no need to check the effective block timestamp here as it will always be in effect
        return nextToLastInvalidation.timestampInMs;
      }
    }

    return 0;
  }
}
