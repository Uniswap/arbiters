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
}
