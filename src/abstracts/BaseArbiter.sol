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
 * @dev Provides ETH refund mechanisms, claim submission, and EIP-712 hash derivation
 */
abstract contract BaseArbiter {
    using FixedPointMathLib for uint256;

    address public constant TRIBUNAL_ADDRESS = 0x000000000000790009689f43bAedb61D67D45bB8;
    ITheCompactClaims public immutable THE_COMPACT = ITheCompactClaims(0x00000000000000171ede64904551eeDF3C6C9788);
    ITribunal public immutable TRIBUNAL = ITribunal(TRIBUNAL_ADDRESS);
    uint256 public immutable BASE_SCALING_FACTOR = 1e18;

    /// @dev Validates emitter matches this contract (deterministic deployment)
    function _validateMessageSender(address emitter) internal view {
        require(emitter == address(this), "Message not from corresponding arbiter");
    }

    /// @dev Refunds entire contract balance to msg.sender after function execution
    modifier refundExcessEth() {
        _;
        _refundExcessEth();
    }

    /// @dev Refunds entire contract balance to msg.sender
    function _refundExcessEth() internal {
        uint256 toRefund = address(this).balance;
        if (toRefund > 0) {
            (bool success,) = msg.sender.call{value: toRefund}("");
            require(success, "ETH refund failed");
        }
    }

    /// @dev Submits BatchClaim to THE_COMPACT.batchClaim()
    function _sendClaim(BatchClaim memory claimPayload) internal virtual returns (bytes32 claimHash) {
        claimHash = THE_COMPACT.batchClaim(claimPayload);
        return claimHash;
    }

    // ======== Claim Hash Helpers ========

    /// @dev Public wrapper for _deriveClaimHash (for off-chain use)
    function deriveClaimHash(address sponsor, uint256 nonce, uint256 expires, bytes32 witness, Lock[] calldata locks)
        public
        view
        returns (bytes32)
    {
        return _deriveClaimHash(sponsor, nonce, expires, witness, locks);
    }

    /// @dev Derives EIP-712 claim hash using COMPACT_TYPEHASH_WITH_MANDATE
    function _deriveClaimHash(address sponsor, uint256 nonce, uint256 expires, bytes32 witness, Lock[] calldata locks)
        internal
        view
        returns (bytes32)
    {
        bytes32 commitmentsHash = _deriveCommitmentsHash(locks);

        // Hash with witness: typehash, arbiter, sponsor, nonce, expires, commitmentsHash, witness
        // Matches Tribunal's _deriveClaimHash using COMPACT_TYPEHASH_WITH_MANDATE
        return keccak256(
            abi.encode(COMPACT_TYPEHASH_WITH_MANDATE, address(this), sponsor, nonce, expires, commitmentsHash, witness)
        );
    }

    /// @dev Hashes Lock array into commitments hash
    function _deriveCommitmentsHash(Lock[] calldata locks) internal pure returns (bytes32) {
        bytes32[] memory lockHashes = new bytes32[](locks.length);
        unchecked {
            for (uint256 i = 0; i < locks.length; ++i) {
                // Hash each lock directly (no extraction needed)
                lockHashes[i] = keccak256(abi.encode(LOCK_TYPEHASH, locks[i].lockTag, locks[i].token, locks[i].amount));
            }
        }

        // Hash all lock hashes together
        return keccak256(abi.encodePacked(lockHashes));
    }

    /// @dev Validates claim is filled in Tribunal, returns claimHash, claimant, and scaling factor
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
