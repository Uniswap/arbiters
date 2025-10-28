// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BatchCompact} from "the-compact/src/types/EIP712Types.sol";

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
 * @notice Contains all data needed to process a claim
 * @dev This struct packages together the compact, signatures, and claim details
 */
struct SendData {
    BatchCompact compact;
    bytes sponsorSignature;
    bytes allocatorSignature;
    bytes32 mandateHash;
    bytes32 claimant;
    uint256[] claimAmounts;
}

/**
 * @notice Represents a batch of claim hashes for a single destination chain
 * @dev Used for BATCH_POST operations where only claim hashes are transmitted
 */
struct BatchPost {
    uint256 chainId;
    bytes32[] claimHashes;
}

/**
 * @notice Represents a batch of full message data for a single destination chain
 * @dev Used for BATCH_SEND operations where complete SendData is transmitted
 */
struct BatchSend {
    uint256 chainId;
    SendData[] messages;
}
