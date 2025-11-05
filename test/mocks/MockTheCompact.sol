// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ClaimHashLib} from "lib/the-compact/src/lib/ClaimHashLib.sol";
import {BatchClaim as CompactBatchClaim} from "the-compact/src/types/BatchClaims.sol";

contract MockTheCompact {
    using ClaimHashLib for CompactBatchClaim;

    bytes32 public latestClaimHash;

    mapping(bytes32 => bool) public claimHashes;

    uint256 public callCount;

    function batchClaim(CompactBatchClaim calldata claim) external returns (bytes32) {
        callCount++;
        (bytes32 claimHash,) = claim.toClaimHashAndTypehash();
        latestClaimHash = claimHash;
        claimHashes[claimHash] = true;
        return latestClaimHash;
    }

    // Explicit getter to ensure it works with etched contracts
    function getClaimHash(bytes32 claimHash) external view returns (bool) {
        return claimHashes[claimHash];
    }

    // Getter for call count
    function getCallCount() external view returns (uint256) {
        return callCount;
    }
}
