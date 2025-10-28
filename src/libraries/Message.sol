// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BatchClaimComponent, Component} from "the-compact/src/types/Components.sol";
import {BatchCompact} from "the-compact/src/types/EIP712Types.sol";
import {BatchClaim as TheCompactBatchClaim} from "lib/the-compact/src/types/BatchClaims.sol";

library Message {
    uint8 constant HAS_ALLOCATOR_SIG = 0x01;
    uint8 constant HAS_SPONSOR_SIG = 0x02;

    function encode(
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        bytes32 claimant,
        uint256[] memory claimAmounts
    ) internal pure returns (bytes memory) {
        require(
            (sponsorSignature.length == 0 || sponsorSignature.length == 64)
                && (allocatorSignature.length == 0 || allocatorSignature.length == 64),
            "invalid message signature length"
        );

        uint256 claimCount = claimAmounts.length;
        uint256 signaturesSize = sponsorSignature.length + allocatorSignature.length;
        uint256 totalSize;
        unchecked {
            totalSize = 137 + signaturesSize + (claimCount * 128);
        }

        bytes memory result = new bytes(totalSize);

        uint8 flags;
        if (allocatorSignature.length == 64) flags |= HAS_ALLOCATOR_SIG;
        if (sponsorSignature.length == 64) flags |= HAS_SPONSOR_SIG;

        assembly ("memory-safe") {
            let ptr := add(result, 32)

            // Fixed header: arbiter (20) + sponsor (20) + nonce (32) + expires (32) = 104 bytes
            mstore(ptr, shl(96, calldataload(compact)))
            mstore(add(ptr, 20), shl(96, calldataload(add(compact, 32))))
            mstore(add(ptr, 40), calldataload(add(compact, 64)))
            mstore(add(ptr, 72), calldataload(add(compact, 96)))

            // Byte 104: flags
            mstore8(add(ptr, 104), flags)

            // Bytes 105-136: mandateHash (32 bytes)
            mstore(add(ptr, 105), mandateHash)
        }

        // Copy signatures at variable offsets
        uint256 offset = 137;
        if (allocatorSignature.length == 64) {
            assembly ("memory-safe") {
                let ptr := add(result, 32)
                calldatacopy(add(ptr, offset), allocatorSignature.offset, 64)
            }
            offset += 64;
        }
        if (sponsorSignature.length == 64) {
            assembly ("memory-safe") {
                let ptr := add(result, 32)
                calldatacopy(add(ptr, offset), sponsorSignature.offset, 64)
            }
            offset += 64;
        }

        unchecked {
            for (uint256 i = 0; i < claimCount; ++i) {
                uint256 id =
                    uint256(bytes32(compact.commitments[i].lockTag)) | uint256(uint160(compact.commitments[i].token));
                uint256 allocatedAmount = compact.commitments[i].amount;
                uint256 amount = claimAmounts[i];

                assembly ("memory-safe") {
                    let ptr := add(add(result, 32), offset)
                    mstore(ptr, id)
                    mstore(add(ptr, 32), allocatedAmount)
                    mstore(add(ptr, 64), claimant)
                    mstore(add(ptr, 96), amount)
                }

                offset += 128;
            }
        }

        return result;
    }

    function decode(bytes calldata message)
        internal
        view
        returns (
            address sponsor,
            uint256 nonce,
            uint256 expires,
            bytes calldata allocatorSignature,
            bytes calldata sponsorSignature,
            bytes32 witness,
            BatchClaimComponent[] memory claims
        )
    {
        uint256 messageLength = message.length;

        require(messageLength >= 137, "message too short");

        uint8 flags;
        unchecked {
            address arbiter;
            assembly ("memory-safe") {
                let msgPtr := message.offset
                arbiter := shr(96, calldataload(msgPtr))
                sponsor := shr(96, calldataload(add(msgPtr, 20)))
                nonce := calldataload(add(msgPtr, 40))
                expires := calldataload(add(msgPtr, 72))
                flags := byte(0, calldataload(add(msgPtr, 104)))
                witness := calldataload(add(msgPtr, 105))
            }
            require(arbiter == address(this), "invalid arbiter");

            // Calculate variable offsets based on flags
            uint256 offset = 137;

            if ((flags & HAS_ALLOCATOR_SIG) != 0) {
                require(messageLength >= offset + 64, "message too short for allocator signature");
                allocatorSignature = message[offset:offset + 64];
                offset += 64;
            } else {
                allocatorSignature = message[0:0];
            }

            if ((flags & HAS_SPONSOR_SIG) != 0) {
                require(messageLength >= offset + 64, "message too short for sponsor signature");
                sponsorSignature = message[offset:offset + 64];
                offset += 64;
            } else {
                sponsorSignature = message[0:0];
            }

            // Remaining bytes are claims
            uint256 claimsSize = messageLength - offset;
            require(claimsSize % 128 == 0, "invalid message length");
            uint256 claimsLength = claimsSize / 128;

            claims = new BatchClaimComponent[](claimsLength);

            for (uint256 i = 0; i < claimsLength; ++i) {
                claims[i].portions = new Component[](1);

                assembly ("memory-safe") {
                    let msgOffset := add(add(message.offset, offset), mul(i, 128))
                    let claimsDataPtr := add(claims, 32)
                    let claimStructPtr := mload(add(claimsDataPtr, mul(i, 32)))

                    mstore(claimStructPtr, calldataload(msgOffset))
                    mstore(add(claimStructPtr, 32), calldataload(add(msgOffset, 32)))

                    let portionsArrayPtr := mload(add(claimStructPtr, 64))
                    let portionStructPtr := mload(add(portionsArrayPtr, 32))

                    mstore(portionStructPtr, calldataload(add(msgOffset, 64)))
                    mstore(add(portionStructPtr, 32), calldataload(add(msgOffset, 96)))
                }
            }
        }
    }

    /**
     * @notice Encodes a batch of claim hashes for BATCH_POST operations
     * @dev Lightweight encoding for user self-relay via wormhole.publishMessage()
     * Format: length (32 bytes) | claimant1 (32) | claimHash1 (32) | claimant2 (32) | claimHash2 (32) | ...
     */
    //TODO: add exact out here with scaling factor
    function encodeBatchPost(bytes32[] memory claimants, bytes32[] memory claimHashes)
        internal
        pure
        returns (bytes memory)
    {
        uint256 length = claimants.length;
        require(length == claimHashes.length, "array length mismatch");

        // 32 bytes for length + (32 + 32) * length for each pair
        bytes memory result = new bytes(32 + (length * 64));

        assembly ("memory-safe") {
            let ptr := add(result, 32)

            // Encode length
            mstore(ptr, length)
            ptr := add(ptr, 32)

            // Encode each claimant|claimHash pair
            let claimantsPtr := add(claimants, 32)
            let hashesPtr := add(claimHashes, 32)

            for { let i := 0 } lt(i, length) { i := add(i, 1) } {
                // Store claimant (32 bytes)
                mstore(ptr, mload(add(claimantsPtr, mul(i, 32))))
                ptr := add(ptr, 32)

                // Store claimHash (32 bytes)
                mstore(ptr, mload(add(hashesPtr, mul(i, 32))))
                ptr := add(ptr, 32)
            }
        }

        return result;
    }

    /**
     * @notice Decodes a batch of claim hashes from BATCH_POST message payload
     * @dev Inverse of encodeBatchPost()
     */
    //TODO: add exact out here with scaling factor
    function decodeBatchPost(bytes memory message)
        internal
        pure
        returns (bytes32[] memory claimants, bytes32[] memory claimHashes)
    {
        require(message.length >= 32, "message too short");

        uint256 length;
        assembly ("memory-safe") {
            length := mload(add(message, 32))
        }

        require(message.length == 32 + (length * 64), "invalid message length");

        claimants = new bytes32[](length);
        claimHashes = new bytes32[](length);

        assembly ("memory-safe") {
            let offset := add(message, 64)
            let claimantsPtr := add(claimants, 32)
            let hashesPtr := add(claimHashes, 32)

            for { let i := 0 } lt(i, length) { i := add(i, 1) } {
                // Load claimant (32 bytes)
                mstore(add(claimantsPtr, mul(i, 32)), mload(offset))
                offset := add(offset, 32)

                // Load claimHash (32 bytes)
                mstore(add(hashesPtr, mul(i, 32)), mload(offset))
                offset := add(offset, 32)
            }
        }
    }

    /**
     * @notice Encodes a batch of TheCompactBatchClaim for BATCH_SEND operations
     * @dev Full encoding for automatic relay via wormholeRelayer.sendPayloadToEvm()
     * Format: count (32 bytes) | length1 (32) | message1 (variable) | length2 (32) | message2 (variable) | ...
     * @param messages Array of TheCompactBatchClaim structs to encode
     * @return Encoded bytes ready for wormholeRelayer.sendPayloadToEvm()
     */
    function encodeBatchSend(TheCompactBatchClaim[] calldata messages) internal pure returns (bytes memory) {
        bytes memory result = abi.encodePacked(uint256(messages.length));

        unchecked {
            for (uint256 i = 0; i < messages.length; ++i) {
                bytes memory encoded = abi.encode(messages[i]);
                result = abi.encodePacked(result, encoded.length, encoded);
            }
        }

        return result;
    }

    /**
     * @notice Decodes a batch of TheCompactBatchClaim from BATCH_SEND message payload
     * @dev Inverse of encodeBatchSend()
     * @param message The encoded message bytes from wormholeRelayer.sendPayloadToEvm()
     * @return claims Array of TheCompactBatchClaim structs
     */
    function decodeBatchSend(bytes calldata message)
        internal
        pure
        returns (TheCompactBatchClaim[] memory claims)
    {
        require(message.length >= 32, "message too short");

        uint256 count;
        assembly ("memory-safe") {
            count := calldataload(message.offset)
        }

        claims = new TheCompactBatchClaim[](count);

        uint256 offset = 32;
        unchecked {
            for (uint256 i = 0; i < count; ++i) {
                require(message.length >= offset + 32, "message too short for length");

                uint256 msgLength;
                assembly ("memory-safe") {
                    msgLength := calldataload(add(message.offset, offset))
                }
                offset += 32;

                require(message.length >= offset + msgLength, "message too short for payload");

                // Extract the message slice and decode
                bytes calldata msgSlice = message[offset:offset + msgLength];
                claims[i] = abi.decode(msgSlice, (TheCompactBatchClaim));

                offset += msgLength;
            }
        }
    }
}
