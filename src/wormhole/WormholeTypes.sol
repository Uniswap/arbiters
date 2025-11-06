// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Lock} from "the-compact/src/types/EIP712Types.sol";

/**
 * @notice Enum to distinguish between different message packing types
 * @dev Used to determine how messages are encoded and transmitted via Wormhole
 */
enum MessagePackingType {
    SINGLE_SEND,
    BATCH_SEND,
    SINGLE_POST,
    BATCH_POST
}

/**
 * @notice Represents a batch of claim hashes for a single destination chain
 * @dev Used for BATCH_POST operations where claim hashes and scaling factors are transmitted
 */
struct BatchPost {
    uint256 chainId; //chainId where the resource lock lives
    bytes32[] claimHashes; // The claim hashes to post
    uint256[] scalingFactors; // The scaling factors for each claim (1e18 = no reduction)
}

struct BatchSend{
    uint256 chainId; //chainId where the resource locks live
    BatchClaimWithLocks[] claims; // array of claims to send
    uint128 gasLimit; //gasLimit for message execution and delivery
    uint256 totalCost; // from Executor pricing API
    bytes signedQuote; // from Executor pricing API
}

/**
 * @notice Represents a batch of full message data for a single destination chain
 * @dev Used for BATCH_POST operations where compact with commitments is provided
 */
struct BatchClaimWithLocks {
    address sponsor; // The account to source the tokens from.
    uint256 nonce; // A parameter to enforce replay protection, scoped to allocator.
    uint256 expires; // The time at which the claim expires.
    bytes32 witness; // Hash of the witness data.
    bytes allocatorData; // Authorization from the allocator.
    bytes sponsorSignature; // Authorization from the sponsor.
    Lock[] commitments; // The committed locks with lock tags, tokens, & amounts.
}

/**
 * @notice Wormhole-specific parameters for send operations
 * @dev Groups relayer parameters to reduce stack depth
 */
struct WormholeParams {
    uint128 gasLimit; // Gas limit for execution on destination chain
    uint256 totalCost; // Total cost from Executor pricing API
}
