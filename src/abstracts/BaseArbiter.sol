// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ITheCompactClaims} from "the-compact/src/interfaces/ITheCompactClaims.sol";
import {ITribunal} from "tribunal/interfaces/ITribunal.sol";
import {BatchClaim} from "lib/the-compact/src/types/BatchClaims.sol";
import {Lock} from "the-compact/src/types/EIP712Types.sol";
import {COMPACT_TYPEHASH_WITH_MANDATE} from "tribunal/types/TribunalTypeHashes.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LOCK_TYPEHASH} from "the-compact/src/types/EIP712Types.sol";

/**
 * @title BaseArbiter
 * @notice Abstract base contract providing common arbiter functionality
 * @dev Provides ETH refund mechanisms and claim submission logic for arbiter implementations
 */
abstract contract BaseArbiter {
    using FixedPointMathLib for uint256;

    address public constant TRIBUNAL_ADDRESS = 0x000000000000790009689f43bAedb61D67D45bB8; // TODO: Set actual Tribunal address for production    
    ITheCompactClaims public immutable THE_COMPACT = ITheCompactClaims(0x00000000000000171ede64904551eeDF3C6C9788);
    ITribunal public immutable TRIBUNAL = ITribunal(TRIBUNAL_ADDRESS);
    uint256 public immutable BASE_SCALING_FACTOR = 1e18;

    /**
     * @notice Validates that a message came from the corresponding arbiter on another chain
     * @dev Checks that the emitter address matches this contract's address (deterministic across chains)
     */
    function _validateMessageSender(address emitter) internal view {
        require(emitter == address(this), "Message not from corresponding arbiter");
    }

    /**
     * @notice Modifier to automatically refund excess ETH after function execution
     * @dev Follows the router pattern - refunds entire contract balance to msg.sender
     */
    modifier refundExcessEth() {
        _;
        _refundExcessEth();
    }

    /**
     * @notice Internal function to refund excess ETH to msg.sender
     * @dev Refunds entire contract balance to msg.sender
     */
    function _refundExcessEth() internal {
        uint256 toRefund = address(this).balance;
        if (toRefund > 0) {
            (bool success,) = msg.sender.call{value: toRefund}("");
            require(success, "ETH refund failed");
        }
    }

    /**
     * @notice Internal function to submit a batch claim to The Compact
     * @dev Accepts a fully constructed BatchClaim and submits it to THE_COMPACT.batchClaim()
     */
    // override if modifications are needed
    function _sendClaim(BatchClaim memory claimPayload) internal returns (bytes32 claimHash) {
        claimHash = THE_COMPACT.batchClaim(claimPayload);
        return claimHash;
    }

    // ============================================================================
    // CLAIM HASH HELPERS (memory-compatible alternative to ClaimHashLib)
    // ============================================================================

    /**
     * @notice Derives the EIP-712 claim hash from Lock array
     * @dev Uses COMPACT_TYPEHASH_WITH_MANDATE which includes the Mandate witness type
     * @dev Public view function for external access to claim hash derivation
     * @param sponsor The account to source tokens from
     * @param nonce Replay protection nonce
     * @param expires Expiration timestamp
     * @param witness Hash of the witness (mandate) data
     * @param locks Array of locks (lockTag, token, amount)
     * @return claimHash The EIP-712 claim hash
     */
    function deriveClaimHash(
        address sponsor,
        uint256 nonce,
        uint256 expires,
        bytes32 witness,
        Lock[] calldata locks
    ) public view returns (bytes32) {
        return _deriveClaimHash(sponsor, nonce, expires, witness, locks);
    }

    /**
     * @notice Internal function to derive the EIP-712 claim hash from Lock array
     * @dev Uses COMPACT_TYPEHASH_WITH_MANDATE which includes the Mandate witness type
     * @param sponsor The account to source tokens from
     * @param nonce Replay protection nonce
     * @param expires Expiration timestamp
     * @param witness Hash of the witness (mandate) data
     * @param locks Array of locks (lockTag, token, amount)
     * @return claimHash The EIP-712 claim hash
     */
    function _deriveClaimHash(
        address sponsor,
        uint256 nonce,
        uint256 expires,
        bytes32 witness,
        Lock[] calldata locks
    ) internal view returns (bytes32) {
        bytes32 commitmentsHash = _deriveCommitmentsHash(locks);

        // Hash with witness: typehash, arbiter, sponsor, nonce, expires, commitmentsHash, witness
        // Matches Tribunal's _deriveClaimHash using COMPACT_TYPEHASH_WITH_MANDATE
        return keccak256(
            abi.encode(
                COMPACT_TYPEHASH_WITH_MANDATE,
                address(this), // arbiter
                sponsor,
                nonce,
                expires,
                commitmentsHash,
                witness
            )
        );
    }

    /**
     * @notice Derives the commitments hash from Lock array
     * @dev Each lock is directly hashed without transformation (lockTag, token, amount)
     * @param locks Array of locks
     * @return The EIP-712 commitments hash
     */
    function _deriveCommitmentsHash(Lock[] calldata locks) internal pure returns (bytes32) {
        bytes32[] memory lockHashes = new bytes32[](locks.length);

        unchecked {
            for (uint256 i = 0; i < locks.length; ++i) {
                // Hash each lock directly (no extraction needed)
                lockHashes[i] = keccak256(
                    abi.encode(LOCK_TYPEHASH, locks[i].lockTag, locks[i].token, locks[i].amount)
                );
            }
        }

        // Hash all lock hashes together
        return keccak256(abi.encodePacked(lockHashes));
    }

    /**
     * @notice Validates a claim against Tribunal records
     * @dev Validates that:
     *      - Claim has been filled in Tribunal (via filled())
     *      - Claim hash is correctly derived from locks
     * @param sponsor The account to source tokens from
     * @param nonce Replay protection nonce
     * @param expires Expiration timestamp
     * @param witness Hash of the witness (mandate) data
     * @param locks Array of locks to validate
     * @return claimHash The validated EIP-712 claim hash
     */
    function _validateBatchClaim(
        address sponsor,
        uint256 nonce,
        uint256 expires,
        bytes32 witness,
        Lock[] calldata locks
    ) internal view returns (bytes32 claimHash, bytes32 claimant, uint256 claimReductionScalingFactor) {
        // 1. Derive the claim hash
        claimHash = _deriveClaimHash(sponsor, nonce, expires, witness, locks);

        // 2. Verify claim has been filled in Tribunal
        claimant = TRIBUNAL.filled(claimHash);
        require(claimant != bytes32(0), "Claim not filled in Tribunal");

        // 3. Get the claim reduction scaling factor
        claimReductionScalingFactor = TRIBUNAL.claimReductionScalingFactor(claimHash);

        return (claimHash, claimant, claimReductionScalingFactor);
    }

    

}
