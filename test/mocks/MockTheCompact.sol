// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ClaimHashLib} from "lib/the-compact/src/lib/ClaimHashLib.sol";
import {BatchClaim as CompactBatchClaim} from "the-compact/src/types/BatchClaims.sol";

contract MockTheCompact {
    using ClaimHashLib for CompactBatchClaim;

    bytes32 public latestClaimHash;

    function batchClaim(CompactBatchClaim calldata claim) external returns (bytes32) {
        (bytes32 claimHash,) = claim.toClaimHashAndTypehash();
        latestClaimHash = claimHash;
        return latestClaimHash;
    }
}
