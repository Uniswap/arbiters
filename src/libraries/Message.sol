// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BatchClaimComponent, Component} from "the-compact/src/types/Components.sol";
import {Lock} from "the-compact/src/types/EIP712Types.sol";
import {BatchClaim} from "lib/the-compact/src/types/BatchClaims.sol";
import {BatchClaimWithLocks, WormholeParams} from "../wormhole/WormholeTypes.sol";
import {WITNESS_TYPESTRING} from "tribunal/types/TribunalTypeHashes.sol";

library Message {
    uint8 constant HAS_ALLOCATOR_SIG = 0x01;
    uint8 constant HAS_SPONSOR_SIG = 0x02;
    uint8 constant IS_SEND = 0x04;
    uint8 constant HAS_CLAIM_REDUCTION = 0x08;

    /**
     * @notice Encodes send context for BATCH_SEND operations
     * @dev Format: [flags(1)][allocator data (0 or 64)][sponsor data (0 or 64)][gasLimit (16)][totalCost (32)][signedQuote (variable)]
     * @param allocatorData Allocator signature (0 or 64 bytes)
     * @param sponsorSignature Sponsor signature (0 or 64 bytes)
     * @param params Wormhole parameters (gasLimit, totalCost)
     * @param signedQuote Signed quote from relayer (variable length)
     * @return Encoded context bytes
     */
    function encodeSendContext(
        bytes calldata allocatorData,
        bytes calldata sponsorSignature,
        WormholeParams memory params,
        bytes calldata signedQuote
    ) internal pure returns (bytes memory) {
        require(
            (sponsorSignature.length == 0 || sponsorSignature.length == 64)
                && (allocatorData.length == 0 || allocatorData.length == 64),
            "invalid allocator or sponsor signature length"
        );

        uint8 flags;
        if (allocatorData.length == 64) flags |= HAS_ALLOCATOR_SIG;
        if (sponsorSignature.length == 64) flags |= HAS_SPONSOR_SIG;
        flags |= IS_SEND;

        // Calculate total size: 1 (flags) + allocatorData.length + sponsorSignature.length + 16 (gasLimit) + 32 (totalCost) + signedQuote.length
        uint256 totalSize = 1 + allocatorData.length + sponsorSignature.length + 16 + 32 + signedQuote.length;
        bytes memory result = new bytes(totalSize);

        assembly ("memory-safe") {
            let ptr := add(result, 32)

            // Store flags (1 byte)
            mstore8(ptr, flags)
            ptr := add(ptr, 1)

            // Copy allocator data if present (0 or 64 bytes)
            if gt(allocatorData.length, 0) {
                calldatacopy(ptr, allocatorData.offset, 64)
                ptr := add(ptr, 64)
            }

            // Copy sponsor signature if present (0 or 64 bytes)
            if gt(sponsorSignature.length, 0) {
                calldatacopy(ptr, sponsorSignature.offset, 64)
                ptr := add(ptr, 64)
            }

            // Load params from memory
            let gasLimit := mload(params)
            let totalCost := mload(add(params, 32))

            // Store gasLimit (16 bytes, right-aligned in first 16 bytes)
            mstore(ptr, shl(128, gasLimit))
            ptr := add(ptr, 16)

            // Store totalCost (32 bytes)
            mstore(ptr, totalCost)
            ptr := add(ptr, 32)

            // Copy signedQuote (variable length)
            calldatacopy(ptr, signedQuote.offset, signedQuote.length)
        }

        return result;
    }

    /**
     * @notice Decodes send context from BATCH_SEND operations
     * @dev Inverse of encodeSendContext()
     * @param context Encoded context bytes
     * @return allocatorData Allocator signature (0 or 64 bytes)
     * @return sponsorSignature Sponsor signature (0 or 64 bytes)
     * @return params Wormhole parameters (gasLimit, totalCost)
     * @return signedQuote Signed quote from relayer
     */
    function decodeSendContext(bytes calldata context)
        internal
        pure
        returns (
            bytes calldata allocatorData,
            bytes calldata sponsorSignature,
            WormholeParams memory params,
            bytes calldata signedQuote
        )
    {
        require(context.length >= 49, "context too short"); // Minimum: 1 (flags) + 16 (gasLimit) + 32 (totalCost)

        uint8 flags;
        assembly ("memory-safe") {
            flags := byte(0, calldataload(context.offset))
        }

        uint256 offset = 1;

        // Read allocator data if present
        if ((flags & HAS_ALLOCATOR_SIG) != 0) {
            require(context.length >= offset + 64, "context too short for allocator signature");
            allocatorData = context[offset:offset + 64];
            offset += 64;
        } else {
            allocatorData = context[0:0];
        }

        // Read sponsor signature if present
        if ((flags & HAS_SPONSOR_SIG) != 0) {
            require(context.length >= offset + 64, "context too short for sponsor signature");
            sponsorSignature = context[offset:offset + 64];
            offset += 64;
        } else {
            sponsorSignature = context[0:0];
        }

        // Read gasLimit (16 bytes) and totalCost (32 bytes) into params
        require(context.length >= offset + 48, "context too short for gasLimit and totalCost");
        assembly ("memory-safe") {
            let gasLimit := shr(128, calldataload(add(context.offset, offset)))
            let totalCost := calldataload(add(context.offset, add(offset, 16)))

            // Store in params struct
            mstore(params, gasLimit)
            mstore(add(params, 32), totalCost)
        }
        offset += 48;

        // Read signedQuote (remaining bytes)
        require(context.length >= offset, "context too short for signedQuote");
        signedQuote = context[offset:];
    }

    /**
     * @notice Encodes post context for BATCH_POST operations
     * @dev Format: [flags(1)][allocator data (0 or 64)][sponsor data (0 or 64)]
     * @dev IS_SEND flag is NOT set for post operations
     * @param allocatorData Allocator signature (0 or 64 bytes)
     * @param sponsorSignature Sponsor signature (0 or 64 bytes)
     * @return Encoded context bytes
     */
    function encodePostContext(bytes calldata allocatorData, bytes calldata sponsorSignature)
        internal
        pure
        returns (bytes memory)
    {
        require(
            (sponsorSignature.length == 0 || sponsorSignature.length == 64)
                && (allocatorData.length == 0 || allocatorData.length == 64),
            "invalid allocator or sponsor signature length"
        );

        uint8 flags;
        if (allocatorData.length == 64) flags |= HAS_ALLOCATOR_SIG;
        if (sponsorSignature.length == 64) flags |= HAS_SPONSOR_SIG;
        // Note: IS_SEND flag is NOT set for Post operations, set to 0

        // Calculate total size: 1 (flags) + allocatorData.length + sponsorSignature.length
        uint256 totalSize = 1 + allocatorData.length + sponsorSignature.length;
        bytes memory result = new bytes(totalSize);

        assembly ("memory-safe") {
            let ptr := add(result, 32)

            // Store flags (1 byte)
            mstore8(ptr, flags)
            ptr := add(ptr, 1)

            // Copy allocator data if present (0 or 64 bytes)
            if gt(allocatorData.length, 0) {
                calldatacopy(ptr, allocatorData.offset, 64)
                ptr := add(ptr, 64)
            }

            // Copy sponsor signature if present (0 or 64 bytes)
            if gt(sponsorSignature.length, 0) {
                calldatacopy(ptr, sponsorSignature.offset, 64)
            }
        }

        return result;
    }

    /**
     * @notice Decodes post context from BATCH_POST operations
     * @dev Inverse of encodePostContext()
     * @param context Encoded context bytes
     * @return allocatorData Allocator signature (0 or 64 bytes)
     * @return sponsorSignature Sponsor signature (0 or 64 bytes)
     */
    function decodePostContext(bytes calldata context)
        internal
        pure
        returns (bytes calldata allocatorData, bytes calldata sponsorSignature)
    {
        require(context.length >= 1, "context too short");

        uint8 flags;
        assembly ("memory-safe") {
            flags := byte(0, calldataload(context.offset))
        }

        uint256 offset = 1;

        // Read allocator data if present
        if ((flags & HAS_ALLOCATOR_SIG) != 0) {
            require(context.length >= offset + 64, "context too short for allocator signature");
            allocatorData = context[offset:offset + 64];
            offset += 64;
        } else {
            allocatorData = context[0:0];
        }

        // Read sponsor signature if present
        if ((flags & HAS_SPONSOR_SIG) != 0) {
            require(context.length >= offset + 64, "context too short for sponsor signature");
            sponsorSignature = context[offset:offset + 64];
            offset += 64;
        } else {
            sponsorSignature = context[0:0];
        }

        // Verify we've consumed the entire context
        require(context.length == offset, "context has unexpected trailing data");
    }

    /**
     * @notice Encodes a message with simplified format
     * @dev Format: [sponsor(20)][nonce(32)][expires(32)][witness(32)][claimant(32)][flags(1)]
     *              [allocatorData(0|64)][sponsorSignature(0|64)][claimReductionScalingFactor(0|32)]
     *              [commitments: lockTag(12)|token(20)|amount(32) repeated]
     * @param sponsor The account to source the tokens from
     * @param nonce A parameter to enforce replay protection, scoped to allocator
     * @param expires The time at which the claim expires
     * @param witness Hash of the witness data
     * @param commitments Array of locks (lockTag, token, amount)
     * @param allocatorData Authorization from the allocator (0 or 64 bytes)
     * @param sponsorSignature Authorization from the sponsor (0 or 64 bytes)
     * @param claimant The recipient of the claim
     * @param claimReductionScalingFactor Scaling factor for claim amounts (1e18 = no reduction)
     * @return Encoded message bytes
     */
    function encode(
        address sponsor,
        uint256 nonce,
        uint256 expires,
        bytes32 witness,
        Lock[] calldata commitments,
        bytes calldata allocatorData,
        bytes calldata sponsorSignature,
        bytes32 claimant,
        uint256 claimReductionScalingFactor
    ) internal pure returns (bytes memory) {
        require(
            (sponsorSignature.length == 0 || sponsorSignature.length == 64)
                && (allocatorData.length == 0 || allocatorData.length == 64),
            "invalid signature length"
        );

        // Calculate flags
        uint8 flags;
        if (allocatorData.length == 64) flags |= HAS_ALLOCATOR_SIG;
        if (sponsorSignature.length == 64) flags |= HAS_SPONSOR_SIG;

        uint256 scalingFactorSize = 0;
        if (claimReductionScalingFactor != 1e18) {
            flags |= HAS_CLAIM_REDUCTION;
            scalingFactorSize = 32;
        }

        // Calculate total size
        // Fixed: 20 + 32 + 32 + 32 + 32 + 1 = 149
        // Variable: allocatorData + sponsorSignature + scalingFactor + commitments
        uint256 totalSize =
            149 + allocatorData.length + sponsorSignature.length + scalingFactorSize + (commitments.length * 64);

        bytes memory result = new bytes(totalSize);

        assembly ("memory-safe") {
            let ptr := add(result, 32)

            // Fixed fields: sponsor(20) + nonce(32) + expires(32) + witness(32) + claimant(32) + flags(1) = 149 bytes
            mstore(ptr, shl(96, sponsor)) // sponsor at offset 0
            mstore(add(ptr, 20), nonce) // nonce at offset 20
            mstore(add(ptr, 52), expires) // expires at offset 52
            mstore(add(ptr, 84), witness) // witness at offset 84
            mstore(add(ptr, 116), claimant) // claimant at offset 116
            mstore8(add(ptr, 148), flags) // flags at offset 148

            ptr := add(ptr, 149)

            // Copy allocator data if present (64 bytes)
            if gt(allocatorData.length, 0) {
                calldatacopy(ptr, allocatorData.offset, 64)
                ptr := add(ptr, 64)
            }

            // Copy sponsor signature if present (64 bytes)
            if gt(sponsorSignature.length, 0) {
                calldatacopy(ptr, sponsorSignature.offset, 64)
                ptr := add(ptr, 64)
            }

            // Store claimReductionScalingFactor if not 1e18 (32 bytes)
            if and(flags, 0x08) {
                mstore(ptr, claimReductionScalingFactor)
                ptr := add(ptr, 32)
            }

            // Encode commitments tightly packed
            // Each Lock struct in calldata is ABI-encoded as 3 x 32-byte words = 96 bytes:
            //   - bytes12 lockTag (left-aligned in 32 bytes)
            //   - address token (right-aligned in 32 bytes)
            //   - uint256 amount (32 bytes)
            let commitmentsPtr := commitments.offset
            let commitmentsEnd := add(commitmentsPtr, mul(commitments.length, 96))

            for { let cPtr := commitmentsPtr } lt(cPtr, commitmentsEnd) { cPtr := add(cPtr, 96) } {

                let lockTag := calldataload(cPtr)
                let token := calldataload(add(cPtr, 32))
                let amount := calldataload(add(cPtr, 64))

                // Store lockTag (12 bytes) - bytes12 is already in bytes 0-11 from calldata
                mstore(ptr, lockTag)
                ptr := add(ptr, 12)

                // Store token (20 bytes) - shift address from low position to high position
                mstore(ptr, shl(96, token))
                ptr := add(ptr, 20)

                // Store amount (32 bytes)
                mstore(ptr, amount)
                ptr := add(ptr, 32)
            }
        }

        return result;
    }

    /**
     * @notice Decodes a message with simplified format and returns BatchClaim
     * @dev Transforms Locks into BatchClaimComponents with scaled amounts
     * @dev Each Lock becomes one BatchClaimComponent with id = pack(lockTag, token)
     * @dev Format: [sponsor(20)][nonce(32)][expires(32)][witness(32)][claimant(32)][flags(1)]
     *              [allocatorData(0|64)][sponsorSignature(0|64)][claimReductionScalingFactor(0|32)]
     *              [commitments: lockTag(12)|token(20)|amount(32) repeated]
     * @param message Encoded message bytes
     * @return batchClaim Fully constructed BatchClaim with WITNESS_TYPESTRING
     */
    function decode(bytes calldata message) internal pure returns (BatchClaim memory batchClaim) {
        uint256 messageLength = message.length;
        require(messageLength >= 149, "message too short");

        address sponsor;
        uint256 nonce;
        uint256 expires;
        bytes32 witness;
        bytes32 claimant;
        bytes calldata allocatorData;
        bytes calldata sponsorSignature;
        uint256 claimReductionScalingFactor;

        uint8 flags;
        assembly ("memory-safe") {
            let msgPtr := message.offset
            sponsor := shr(96, calldataload(msgPtr))
            nonce := calldataload(add(msgPtr, 20))
            expires := calldataload(add(msgPtr, 52))
            witness := calldataload(add(msgPtr, 84))
            claimant := calldataload(add(msgPtr, 116))
            flags := byte(0, calldataload(add(msgPtr, 148)))
        }

        uint256 offset = 149;

        // Read allocator data if present
        // Note: No length check needed - message integrity guaranteed by corresponding encode function 
        // and checking to make sure the message came from corresponding arbiter. 
        if ((flags & HAS_ALLOCATOR_SIG) != 0) {
            allocatorData = message[offset:offset + 64];
            offset += 64;
        } else {
            allocatorData = message[0:0];
        }

        // Read sponsor signature if present
        if ((flags & HAS_SPONSOR_SIG) != 0) {
            sponsorSignature = message[offset:offset + 64];
            offset += 64;
        } else {
            sponsorSignature = message[0:0];
        }

        // Read claimReductionScalingFactor if present
        if ((flags & HAS_CLAIM_REDUCTION) != 0) {
            assembly ("memory-safe") {
                claimReductionScalingFactor := calldataload(add(message.offset, offset))
            }
            offset += 32;
        } else {
            claimReductionScalingFactor = 1e18;
        }

        // Decode commitments and transform to BatchClaimComponents
        uint256 remainingBytes = messageLength - offset;
        require(remainingBytes % 64 == 0, "invalid commitments length");
        uint256 commitmentsCount = remainingBytes / 64;

        BatchClaimComponent[] memory claims = new BatchClaimComponent[](commitmentsCount);

        unchecked {
            for (uint256 i = 0; i < commitmentsCount; ++i) {
                bytes12 lockTag;
                address token;
                uint256 amount;

                assembly ("memory-safe") {
                    let msgPtr := add(add(message.offset, offset), mul(i, 64))

                    // Load lockTag (12 bytes)
                    lockTag := calldataload(msgPtr)

                    // Load token (20 bytes)
                    token := shr(96, calldataload(add(msgPtr, 12)))

                    // Load amount (32 bytes)
                    amount := calldataload(add(msgPtr, 32))
                }

                // Pack lockTag + token into id
                uint256 id = uint256(bytes32(lockTag)) | uint256(uint160(token));

                // Calculate scaled amount for component
                uint256 scaledAmount =
                    claimReductionScalingFactor == 1e18 ? amount : ((amount * claimReductionScalingFactor) / 1e18);

                // Create single Component portion
                Component[] memory portions = new Component[](1);
                portions[0] = Component({claimant: uint256(claimant), amount: scaledAmount});

                // Create BatchClaimComponent
                claims[i] = BatchClaimComponent({id: id, allocatedAmount: amount, portions: portions});
            }
        }

        // Construct and return BatchClaim
        batchClaim = BatchClaim({
            allocatorData: allocatorData,
            sponsorSignature: sponsorSignature,
            sponsor: sponsor,
            nonce: nonce,
            expires: expires,
            witness: witness,
            witnessTypestring: WITNESS_TYPESTRING,
            claims: claims
        });
    }

    /**
     * @notice Encodes a batch of claim hashes with scaling factors for BATCH_POST operations
     * @dev Dual bitmap encoding for maximum efficiency with 32-byte aligned header
     * @dev Format: [itemCount(uint16, 2 bytes)][changeClaimants(15 bytes)][scalingFactors(15 bytes)]
     *              [claimants (where changeClaimants bit set)]
     *              [all claimHashes]
     *              [scalingFactors (where scalingFactors bit set)]
     * @dev changeClaimants bitmap: bit i set = new claimant at position i
     * @dev scalingFactors bitmap: bit i set = scalingFactor != 1e18 at position i
     * @dev Pre-group entries by claimant for optimal gas efficiency
     * @dev Max 120 items per batch (15 bytes × 8 bits = 120 bits)
     * @param claimants Array of claimants (one per claim)
     * @param claimHashes Array of claim hashes
     * @param scalingFactors Array of scaling factors (1e18 = no reduction)
     */
    function encodeBatchPost(bytes32[] memory claimants, bytes32[] memory claimHashes, uint256[] memory scalingFactors)
        internal
        pure
        returns (bytes memory)
    {
        uint256 length = claimants.length;
        require(length == claimHashes.length && length == scalingFactors.length, "array length mismatch");
        require(length <= 120, "Max 120 claims per batch");

        if (length == 0) {
            return new bytes(32); // Just header with itemCount = 0
        }

        // First pass: build bitmaps and count storage needed
        uint256 changeClaimantsBitmap = 0;
        uint256 scalingFactorsBitmap = 0;
        uint256 claimantCount = 0;
        uint256 nonDefaultFactorCount = 0;

        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                // Check if claimant changes (or is first)
                if (i == 0 || claimants[i] != claimants[i - 1]) {
                    changeClaimantsBitmap |= (1 << i);
                    claimantCount++;
                }
                // Check if scaling factor != 1e18
                if (scalingFactors[i] != 1e18) {
                    scalingFactorsBitmap |= (1 << i);
                    nonDefaultFactorCount++;
                }
            }
        }

        // Calculate total size:
        // 32 bytes (header) +
        // claimantCount * 32 bytes (claimants) +
        // length * 32 bytes (claimHashes) +
        // nonDefaultFactorCount * 32 bytes (scalingFactors)
        uint256 totalSize = 32 + (claimantCount * 32) + (length * 32) + (nonDefaultFactorCount * 32);
        bytes memory result = new bytes(totalSize);

        assembly ("memory-safe") {
            let ptr := add(result, 32)

            // Store header (32 bytes total):
            // Layout: [itemCount: 16 bits][changeClaimants: 120 bits][scalingFactors: 120 bits]
            // Pack all three fields into a single 256-bit value
            let header := or(shl(240, length), or(shl(120, changeClaimantsBitmap), scalingFactorsBitmap))
            mstore(ptr, header)

            ptr := add(ptr, 32)

            let claimantsPtr := add(claimants, 32)
            let hashesPtr := add(claimHashes, 32)
            let factorsPtr := add(scalingFactors, 32)
            let BASE_SCALING := 1000000000000000000 // 1e18

            // Store claimants (only where changeClaimants bit is set)
            for { let i := 0 } lt(i, length) { i := add(i, 1) } {
                if and(shr(i, changeClaimantsBitmap), 1) {
                    mstore(ptr, mload(add(claimantsPtr, mul(i, 32))))
                    ptr := add(ptr, 32)
                }
            }

            // Store all claimHashes
            for { let i := 0 } lt(i, length) { i := add(i, 1) } {
                mstore(ptr, mload(add(hashesPtr, mul(i, 32))))
                ptr := add(ptr, 32)
            }

            // Store non-1e18 scaling factors (only where scalingFactors bit is set)
            for { let i := 0 } lt(i, length) { i := add(i, 1) } {
                if and(shr(i, scalingFactorsBitmap), 1) {
                    mstore(ptr, mload(add(factorsPtr, mul(i, 32))))
                    ptr := add(ptr, 32)
                }
            }
        }

        return result;
    }

    /**
     * @notice Decodes a batch of claim hashes with scaling factors from BATCH_POST message payload
     * @dev Inverse of encodeBatchPost()
     * @dev Decodes dual bitmap format and expands to flat arrays
     * @param message Encoded message bytes
     * @return claimants Array of claimants (one per claim)
     * @return claimHashes Array of claim hashes
     * @return scalingFactors Array of scaling factors (1e18 inserted where bitmap bit=0)
     */
    function decodeBatchPost(bytes memory message)
        internal
        pure
        returns (bytes32[] memory claimants, bytes32[] memory claimHashes, uint256[] memory scalingFactors)
    {
        require(message.length >= 32, "message too short");

        uint16 itemCount;
        uint256 changeClaimantsBitmap;
        uint256 scalingFactorsBitmap;

        assembly ("memory-safe") {
            let ptr := add(message, 32)

            // Read header (32 bytes)
            // Layout: [itemCount: 16 bits][changeClaimants: 120 bits][scalingFactors: 120 bits]
            let header := mload(ptr)

            // Extract itemCount (top 16 bits)
            itemCount := shr(240, header)

            // Extract changeClaimants bitmap (next 120 bits)
            // Shift right 120 bits to remove scalingFactors, then mask to 120 bits
            changeClaimantsBitmap := and(shr(120, header), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF)

            // Extract scalingFactors bitmap (bottom 120 bits)
            scalingFactorsBitmap := and(header, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }

        if (itemCount == 0) {
            return (new bytes32[](0), new bytes32[](0), new uint256[](0));
        }

        // Allocate result arrays
        claimants = new bytes32[](itemCount);
        claimHashes = new bytes32[](itemCount);
        scalingFactors = new uint256[](itemCount);

        assembly ("memory-safe") {
            let ptr := add(add(message, 32), 32) // Skip length prefix + header
            let claimantsPtr := add(claimants, 32)
            let hashesPtr := add(claimHashes, 32)
            let factorsPtr := add(scalingFactors, 32)
            let BASE_SCALING := 1000000000000000000 // 1e18

            let currentClaimant := 0

            // Read claimants and expand using changeClaimants bitmap
            for { let i := 0 } lt(i, itemCount) { i := add(i, 1) } {
                if and(shr(i, changeClaimantsBitmap), 1) {
                    // Bit is set - read new claimant
                    currentClaimant := mload(ptr)
                    ptr := add(ptr, 32)
                }
                // Store claimant (either new or reused)
                mstore(add(claimantsPtr, mul(i, 32)), currentClaimant)
            }

            // Read all claimHashes
            for { let i := 0 } lt(i, itemCount) { i := add(i, 1) } {
                mstore(add(hashesPtr, mul(i, 32)), mload(ptr))
                ptr := add(ptr, 32)
            }

            // Read scaling factors and expand using scalingFactors bitmap
            for { let i := 0 } lt(i, itemCount) { i := add(i, 1) } {
                let factor := BASE_SCALING // Default to 1e18
                if and(shr(i, scalingFactorsBitmap), 1) {
                    // Bit is set - read scaling factor from message
                    factor := mload(ptr)
                    ptr := add(ptr, 32)
                }
                // Store the factor (either read or default)
                mstore(add(factorsPtr, mul(i, 32)), factor)
            }
        }
    }

    /**
     * @notice Encodes a batch of BatchClaimWithLocks for BATCH_SEND operations
     * @dev Full encoding for automatic relay via wormholeRelayer.sendPayloadToEvm()
     * @dev Format: count (32 bytes) | length1 (32) | message1 (variable) | length2 (32) | message2 (variable) | ...
     * @param claimants Array of claimants (one per claim)
     * @param claimReductionScalingFactors Array of scaling factors (one per claim, 1e18 = no reduction)
     * @param claims Array of BatchClaimWithLocks structs to encode
     * @return Encoded bytes ready for wormholeRelayer.sendPayloadToEvm()
     */
    function encodeBatchSend(
        bytes32[] memory claimants,
        uint256[] memory claimReductionScalingFactors,
        BatchClaimWithLocks[] calldata claims
    ) internal pure returns (bytes memory) {
        bytes memory result = abi.encodePacked(uint256(claims.length));

        unchecked {
            for (uint256 i = 0; i < claims.length; ++i) {
                BatchClaimWithLocks calldata claim = claims[i]; // doing this to avoid stack too deep error
                bytes memory encoded = encode(
                    claim.sponsor,
                    claim.nonce,
                    claim.expires,
                    claim.witness,
                    claim.commitments,
                    claim.allocatorData,
                    claim.sponsorSignature,
                    claimants[i],
                    claimReductionScalingFactors[i]
                );
                result = abi.encodePacked(result, encoded.length, encoded);
            }
        }
        return result;
    }

    /**
     * @notice Decodes a batch of BatchClaim from BATCH_SEND message payload
     * @dev Inverse of encodeBatchSend()
     * @param message The encoded message bytes from wormholeRelayer.sendPayloadToEvm()
     * @return claims Array of BatchClaim structs
     */
    function decodeBatchSend(bytes calldata message) internal pure returns (BatchClaim[] memory claims) {
        require(message.length >= 32, "message too short");

        uint256 count;
        assembly ("memory-safe") {
            count := calldataload(message.offset)
        }

        claims = new BatchClaim[](count);

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

                // Extract the message slice and decode using custom decode()
                bytes calldata msgSlice = message[offset:offset + msgLength];
                claims[i] = decode(msgSlice);

                offset += msgLength;
            }
        }
    }
}
