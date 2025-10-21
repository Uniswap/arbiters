// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BatchClaimComponent, Component} from "the-compact/src/types/Components.sol";
import {BatchCompact} from "the-compact/src/types/EIP712Types.sol";

library Message {
    function encode(
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        bytes32 claimant,
        uint256[] memory claimAmounts
    ) internal pure returns (bytes memory) {
        require(sponsorSignature.length == 64 && allocatorSignature.length == 64, "invalid message signature length");

        uint256 claimCount = claimAmounts.length;
        uint256 totalSize;
        unchecked {
            totalSize = 264 + (claimCount * 128);
        }

        bytes memory result = new bytes(totalSize);

        assembly ("memory-safe") {
            let ptr := add(result, 32)

            mstore(ptr, shl(96, calldataload(compact)))
            mstore(add(ptr, 20), shl(96, calldataload(add(compact, 32))))
            mstore(add(ptr, 40), calldataload(add(compact, 64)))
            mstore(add(ptr, 72), calldataload(add(compact, 96)))
            mstore(add(ptr, 104), mandateHash)

            calldatacopy(add(ptr, 136), allocatorSignature.offset, 64)
            calldatacopy(add(ptr, 200), sponsorSignature.offset, 64)
        }

        unchecked {
            uint256 offset = 264;

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
        require(messageLength >= 264, "message too short");

        unchecked {
            uint256 claimsSize = messageLength - 264;
            require(claimsSize % 128 == 0, "invalid message length");
            uint256 claimsLength = claimsSize / 128;

            address arbiter;
            assembly ("memory-safe") {
                arbiter := shr(96, calldataload(message.offset))
            }
            require(arbiter == address(this), "invalid arbiter");

            assembly ("memory-safe") {
                let msgPtr := message.offset

                sponsor := shr(96, calldataload(add(msgPtr, 20)))
                nonce := calldataload(add(msgPtr, 40))
                expires := calldataload(add(msgPtr, 72))
                witness := calldataload(add(msgPtr, 104))
            }

            allocatorSignature = message[136:200];
            sponsorSignature = message[200:264];

            claims = new BatchClaimComponent[](claimsLength);

            for (uint256 i = 0; i < claimsLength; ++i) {
                claims[i].portions = new Component[](1);

                assembly ("memory-safe") {
                    let msgOffset := add(add(message.offset, 264), mul(i, 128))
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
