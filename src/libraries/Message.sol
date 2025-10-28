// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BatchClaimComponent, Component} from "the-compact/src/types/Components.sol";
import {BatchCompact} from "the-compact/src/types/EIP712Types.sol";

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
     *
     * Format: chainId (32 bytes) | array length (32 bytes) | claimHashes (32 bytes each)
     *
     * Implementation steps:
     * 1. Calculate total size: 64 + (claimHashes.length * 32)
     * 2. Create bytes array of calculated size
     * 3. Encode chainId at offset 0 (32 bytes)
     * 4. Encode array length at offset 32 (32 bytes)
     * 5. Loop through claimHashes and encode each at offset 64 + (i * 32)
     * 6. Return encoded bytes
     *
     * Note: The nonce parameter is NOT included in payload - it's passed separately
     * to wormhole.publishMessage() as the nonce parameter
     *
     * @param chainId The destination chain ID
     * @param claimHashes Array of claim hashes to encode
     * @return Encoded bytes ready for wormhole.publishMessage()
     */
    function encodeBatchPost(
        uint256 chainId,
        bytes32[] memory claimHashes
    ) internal pure returns (bytes memory) {
        // TODO: implement encoding logic
        // Format: chainId | length | claimHash1 | claimHash2 | ...
    }

    /**
     * @notice Encodes a batch of full SendData for BATCH_SEND operations
     * @dev Full encoding for automatic relay via wormholeRelayer.sendPayloadToEvm()
     *
     * Format: MessagePackingType (1 byte) | chainId (32 bytes) | array length (32 bytes) | SendData[]
     *
     * Implementation steps:
     * 1. Calculate total size needed:
     *    - 1 byte for MessagePackingType
     *    - 32 bytes for chainId
     *    - 32 bytes for array length
     *    - For each message: calculate size using existing encode() logic
     * 2. Create bytes array of calculated size
     * 3. Encode MessagePackingType.BATCH_SEND at offset 0 (1 byte)
     * 4. Encode chainId at offset 1 (32 bytes)
     * 5. Encode array length at offset 33 (32 bytes)
     * 6. Loop through messages:
     *    - For each message, call encode() with message data
     *    - Append encoded message to result at current offset
     *    - Update offset by encoded message length
     * 7. Return encoded bytes
     *
     * Note: MessagePackingType is included in payload (not nonce) because
     * sendPayloadToEvm() doesn't have a nonce parameter
     *
     * @param chainId The destination chain ID
     * @param messages Array of SendData structs to encode
     * @return Encoded bytes ready for wormholeRelayer.sendPayloadToEvm()
     */
    function encodeBatchSend(
        uint256 chainId,
        SendData[] memory messages
    ) internal pure returns (bytes memory) {
        // TODO: implement encoding logic
        // Format: MessagePackingType | chainId | length | message1 | message2 | ...
        // Each message uses the existing encode() function logic
    }

    /**
     * @notice Decodes a batch of claim hashes from BATCH_POST message payload
     * @dev Inverse of encodeBatchPost()
     *
     * Format: chainId (32 bytes) | array length (32 bytes) | claimHashes (32 bytes each)
     *
     * Implementation steps:
     * 1. Validate message length >= 64 bytes (minimum for chainId + length)
     * 2. Decode chainId from offset 0 (32 bytes)
     * 3. Decode array length from offset 32 (32 bytes)
     * 4. Validate message length == 64 + (arrayLength * 32)
     * 5. Create claimHashes array of decoded length
     * 6. Loop through and decode each claimHash at offset 64 + (i * 32)
     * 7. Return chainId and claimHashes array
     *
     * @param message The encoded message bytes from wormhole.publishMessage()
     * @return chainId The destination chain ID
     * @return claimHashes Array of decoded claim hashes
     */
    function decodeBatchPost(bytes calldata message)
        internal
        pure
        returns (
            uint256 chainId,
            bytes32[] memory claimHashes
        )
    {
        // TODO: implement decoding logic
        // Format: chainId | length | claimHash1 | claimHash2 | ...
    }

    /**
     * @notice Decodes a batch of SendData from BATCH_SEND message payload
     * @dev Inverse of encodeBatchSend()
     *
     * Format: MessagePackingType (1 byte) | chainId (32 bytes) | array length (32 bytes) | SendData[]
     *
     * Implementation steps:
     * 1. Validate message length >= 65 bytes (minimum for type + chainId + length)
     * 2. Decode and validate MessagePackingType at offset 0 (should be BATCH_SEND)
     * 3. Decode chainId from offset 1 (32 bytes)
     * 4. Decode array length from offset 33 (32 bytes)
     * 5. Create SendData array of decoded length
     * 6. Track current offset starting at 65
     * 7. Loop through messages:
     *    - For each message, calculate the message size based on flags
     *    - Extract message slice from current offset
     *    - Decode using existing decode() logic or inline decoding
     *    - Store decoded SendData in array
     *    - Update offset by message size
     * 8. Return chainId and messages array
     *
     * @param message The encoded message bytes from wormholeRelayer.sendPayloadToEvm()
     * @return chainId The destination chain ID
     * @return messages Array of decoded SendData structs
     */
    function decodeBatchSend(bytes calldata message)
        internal
        pure
        returns (
            uint256 chainId,
            SendData[] memory messages
        )
    {
        // TODO: implement decoding logic
        // Format: MessagePackingType | chainId | length | message1 | message2 | ...
        // Each message needs to be decoded using logic similar to existing decode()
    }

    // Note: SendData struct is defined in WormholeTribunal.sol
    // We'll need to either import it or pass the struct components separately
    struct SendData {
        BatchCompact compact;
        bytes sponsorSignature;
        bytes allocatorSignature;
        bytes32 mandateHash;
        bytes32 claimant;
        uint256[] claimAmounts;
    }
}
