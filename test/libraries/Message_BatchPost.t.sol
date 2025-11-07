// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Message} from "../../src/libraries/Message.sol";

/// @title MessageBatchPostWrapper
/// @notice Wrapper contract to call Message batch post functions in tests
/// @dev Needed because library functions use memory parameters
contract MessageBatchPostWrapper {
    function encodeBatchPost(bytes32[] memory claimants, bytes32[] memory claimHashes, uint256[] memory scalingFactors)
        external
        pure
        returns (bytes memory)
    {
        return Message.encodeBatchPost(claimants, claimHashes, scalingFactors);
    }

    function decodeBatchPost(bytes memory message)
        external
        pure
        returns (bytes32[] memory claimants, bytes32[] memory claimHashes, uint256[] memory scalingFactors)
    {
        return Message.decodeBatchPost(message);
    }
}

/// @title MessageBatchPostTest
/// @notice Test suite for encodeBatchPost and decodeBatchPost functions
/// @dev Tests dual bitmap encoding/decoding with various configurations
contract MessageBatchPostTest is Test {
    MessageBatchPostWrapper public wrapper;

    // Test constants - Using distinctive non-zero patterns to catch encoding errors
    bytes32 constant CLAIMANT_1 = 0x9999999999999999999999999999999999999999999999999999999999999999; // All 9s
    bytes32 constant CLAIMANT_2 = 0x8888888888888888888888888888888888888888888888888888888888888888; // All 8s
    bytes32 constant CLAIMANT_3 = 0x7777777777777777777777777777777777777777777777777777777777777777; // All 7s
    bytes32 constant CLAIMANT_4 = 0x6666666666666666666666666666666666666666666666666666666666666666; // All 6s

    bytes32 constant CLAIM_HASH_1 = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; // All As
    bytes32 constant CLAIM_HASH_2 = 0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; // All Bs
    bytes32 constant CLAIM_HASH_3 = 0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc; // All Cs
    bytes32 constant CLAIM_HASH_4 = 0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd; // All Ds

    uint256 constant SCALING_FACTOR_FULL = 1e18;
    uint256 constant SCALING_FACTOR_HALF = 0.5e18;
    uint256 constant SCALING_FACTOR_QUARTER = 0.25e18;

    function setUp() public {
        wrapper = new MessageBatchPostWrapper();
    }

    /// @notice Helper to assert arrays equality
    function assertArraysEqual(bytes32[] memory expected, bytes32[] memory actual, string memory errorMsg) internal pure {
        require(expected.length == actual.length, string.concat(errorMsg, ": length mismatch"));
        for (uint256 i = 0; i < expected.length; i++) {
            if (expected[i] != actual[i]) {
                // Log which index failed for debugging
                revert(string.concat(errorMsg, ": element mismatch at index"));
            }
        }
    }

    function assertArraysEqual(uint256[] memory expected, uint256[] memory actual, string memory errorMsg) internal pure {
        require(expected.length == actual.length, string.concat(errorMsg, ": length mismatch"));
        for (uint256 i = 0; i < expected.length; i++) {
            if (expected[i] != actual[i]) {
                // Log which index failed for debugging
                revert(string.concat(errorMsg, ": element mismatch at index"));
            }
        }
    }

    //////////////////////////////////////////////////////////////
    // ROUND TRIP TESTS
    //////////////////////////////////////////////////////////////

    /// @notice Test round trip with empty batch
    function test_batchPost_roundTrip_emptyBatch() public view {
        bytes32[] memory claimants = new bytes32[](0);
        bytes32[] memory claimHashes = new bytes32[](0);
        uint256[] memory scalingFactors = new uint256[](0);

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
        (bytes32[] memory decodedClaimants, bytes32[] memory decodedHashes, uint256[] memory decodedFactors) =
            wrapper.decodeBatchPost(encoded);

        require(decodedClaimants.length == 0, "claimants length should be 0");
        require(decodedHashes.length == 0, "hashes length should be 0");
        require(decodedFactors.length == 0, "factors length should be 0");
    }

    /// @notice Test round trip with single item
    function test_batchPost_roundTrip_singleItem() public view {
        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = CLAIMANT_1;

        bytes32[] memory claimHashes = new bytes32[](1);
        claimHashes[0] = CLAIM_HASH_1;

        uint256[] memory scalingFactors = new uint256[](1);
        scalingFactors[0] = SCALING_FACTOR_FULL;

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
        (bytes32[] memory decodedClaimants, bytes32[] memory decodedHashes, uint256[] memory decodedFactors) =
            wrapper.decodeBatchPost(encoded);

        assertArraysEqual(claimants, decodedClaimants, "claimants");
        assertArraysEqual(claimHashes, decodedHashes, "hashes");
        assertArraysEqual(scalingFactors, decodedFactors, "factors");
    }

    /// @notice Test round trip with single item and non-default scaling factor
    function test_batchPost_roundTrip_singleItem_withScaling() public view {
        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = CLAIMANT_1;

        bytes32[] memory claimHashes = new bytes32[](1);
        claimHashes[0] = CLAIM_HASH_1;

        uint256[] memory scalingFactors = new uint256[](1);
        scalingFactors[0] = SCALING_FACTOR_HALF;

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
        (bytes32[] memory decodedClaimants, bytes32[] memory decodedHashes, uint256[] memory decodedFactors) =
            wrapper.decodeBatchPost(encoded);

        assertArraysEqual(claimants, decodedClaimants, "claimants");
        assertArraysEqual(claimHashes, decodedHashes, "hashes");
        assertArraysEqual(scalingFactors, decodedFactors, "factors");
    }

    /// @notice Test round trip with multiple items, same claimant
    function test_batchPost_roundTrip_multipleItems_sameClaimant() public view {
        bytes32[] memory claimants = new bytes32[](3);
        claimants[0] = CLAIMANT_1;
        claimants[1] = CLAIMANT_1;
        claimants[2] = CLAIMANT_1;

        bytes32[] memory claimHashes = new bytes32[](3);
        claimHashes[0] = CLAIM_HASH_1;
        claimHashes[1] = CLAIM_HASH_2;
        claimHashes[2] = CLAIM_HASH_3;

        uint256[] memory scalingFactors = new uint256[](3);
        scalingFactors[0] = SCALING_FACTOR_FULL;
        scalingFactors[1] = SCALING_FACTOR_FULL;
        scalingFactors[2] = SCALING_FACTOR_FULL;

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
        (bytes32[] memory decodedClaimants, bytes32[] memory decodedHashes, uint256[] memory decodedFactors) =
            wrapper.decodeBatchPost(encoded);

        assertArraysEqual(claimants, decodedClaimants, "claimants");
        assertArraysEqual(claimHashes, decodedHashes, "hashes");
        assertArraysEqual(scalingFactors, decodedFactors, "factors");
    }

    /// @notice Test round trip with multiple items, all different claimants
    function test_batchPost_roundTrip_multipleItems_differentClaimants() public view {
        bytes32[] memory claimants = new bytes32[](4);
        claimants[0] = CLAIMANT_1;
        claimants[1] = CLAIMANT_2;
        claimants[2] = CLAIMANT_3;
        claimants[3] = CLAIMANT_4;

        bytes32[] memory claimHashes = new bytes32[](4);
        claimHashes[0] = CLAIM_HASH_1;
        claimHashes[1] = CLAIM_HASH_2;
        claimHashes[2] = CLAIM_HASH_3;
        claimHashes[3] = CLAIM_HASH_4;

        uint256[] memory scalingFactors = new uint256[](4);
        scalingFactors[0] = SCALING_FACTOR_FULL;
        scalingFactors[1] = SCALING_FACTOR_FULL;
        scalingFactors[2] = SCALING_FACTOR_FULL;
        scalingFactors[3] = SCALING_FACTOR_FULL;

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
        (bytes32[] memory decodedClaimants, bytes32[] memory decodedHashes, uint256[] memory decodedFactors) =
            wrapper.decodeBatchPost(encoded);

        assertArraysEqual(claimants, decodedClaimants, "claimants");
        assertArraysEqual(claimHashes, decodedHashes, "hashes");
        assertArraysEqual(scalingFactors, decodedFactors, "factors");
    }

    /// @notice Test round trip with mixed claimants pattern (some consecutive duplicates)
    function test_batchPost_roundTrip_mixedClaimants() public view {
        bytes32[] memory claimants = new bytes32[](8);
        claimants[0] = CLAIMANT_1;
        claimants[1] = CLAIMANT_1;
        claimants[2] = CLAIMANT_1;
        claimants[3] = CLAIMANT_2;
        claimants[4] = CLAIMANT_2;
        claimants[5] = CLAIMANT_3;
        claimants[6] = CLAIMANT_3;
        claimants[7] = CLAIMANT_3;

        bytes32[] memory claimHashes = new bytes32[](8);
        for (uint256 i = 0; i < 8; i++) {
            claimHashes[i] = bytes32(uint256(CLAIM_HASH_1) + i);
        }

        uint256[] memory scalingFactors = new uint256[](8);
        for (uint256 i = 0; i < 8; i++) {
            scalingFactors[i] = SCALING_FACTOR_FULL;
        }

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
        (bytes32[] memory decodedClaimants, bytes32[] memory decodedHashes, uint256[] memory decodedFactors) =
            wrapper.decodeBatchPost(encoded);

        assertArraysEqual(claimants, decodedClaimants, "claimants");
        assertArraysEqual(claimHashes, decodedHashes, "hashes");
        assertArraysEqual(scalingFactors, decodedFactors, "factors");
    }

    /// @notice Test round trip with all non-default scaling factors
    function test_batchPost_roundTrip_allNonDefaultScaling() public view {
        bytes32[] memory claimants = new bytes32[](4);
        claimants[0] = CLAIMANT_1;
        claimants[1] = CLAIMANT_1;
        claimants[2] = CLAIMANT_1;
        claimants[3] = CLAIMANT_1;

        bytes32[] memory claimHashes = new bytes32[](4);
        claimHashes[0] = CLAIM_HASH_1;
        claimHashes[1] = CLAIM_HASH_2;
        claimHashes[2] = CLAIM_HASH_3;
        claimHashes[3] = CLAIM_HASH_4;

        uint256[] memory scalingFactors = new uint256[](4);
        scalingFactors[0] = SCALING_FACTOR_HALF;
        scalingFactors[1] = SCALING_FACTOR_QUARTER;
        scalingFactors[2] = 0.4e18;
        scalingFactors[3] = 0.75e18;

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
        (bytes32[] memory decodedClaimants, bytes32[] memory decodedHashes, uint256[] memory decodedFactors) =
            wrapper.decodeBatchPost(encoded);

        assertArraysEqual(claimants, decodedClaimants, "claimants");
        assertArraysEqual(claimHashes, decodedHashes, "hashes");
        assertArraysEqual(scalingFactors, decodedFactors, "factors");
    }

    /// @notice Test round trip with mixed scaling factors
    function test_batchPost_roundTrip_mixedScaling() public view {
        bytes32[] memory claimants = new bytes32[](6);
        for (uint256 i = 0; i < 6; i++) {
            claimants[i] = CLAIMANT_1;
        }

        bytes32[] memory claimHashes = new bytes32[](6);
        for (uint256 i = 0; i < 6; i++) {
            claimHashes[i] = bytes32(uint256(CLAIM_HASH_1) + i);
        }

        uint256[] memory scalingFactors = new uint256[](6);
        scalingFactors[0] = SCALING_FACTOR_FULL; // Default (not stored)
        scalingFactors[1] = SCALING_FACTOR_HALF; // Non-default (stored)
        scalingFactors[2] = SCALING_FACTOR_FULL; // Default (not stored)
        scalingFactors[3] = SCALING_FACTOR_FULL; // Default (not stored)
        scalingFactors[4] = SCALING_FACTOR_QUARTER; // Non-default (stored)
        scalingFactors[5] = SCALING_FACTOR_FULL; // Default (not stored)

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
        (bytes32[] memory decodedClaimants, bytes32[] memory decodedHashes, uint256[] memory decodedFactors) =
            wrapper.decodeBatchPost(encoded);

        assertArraysEqual(claimants, decodedClaimants, "claimants");
        assertArraysEqual(claimHashes, decodedHashes, "hashes");
        assertArraysEqual(scalingFactors, decodedFactors, "factors");
    }

    /// @notice Test round trip with single zero scaling factor (cancelled claim)
    function test_batchPost_roundTrip_singleItem_zeroScaling() public view {
        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = CLAIMANT_1;

        bytes32[] memory claimHashes = new bytes32[](1);
        claimHashes[0] = CLAIM_HASH_1;

        uint256[] memory scalingFactors = new uint256[](1);
        scalingFactors[0] = 0; // Zero scaling factor = cancelled claim

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
        (bytes32[] memory decodedClaimants, bytes32[] memory decodedHashes, uint256[] memory decodedFactors) =
            wrapper.decodeBatchPost(encoded);

        assertArraysEqual(claimants, decodedClaimants, "claimants");
        assertArraysEqual(claimHashes, decodedHashes, "hashes");
        assertArraysEqual(scalingFactors, decodedFactors, "factors");
    }

    /// @notice Test round trip with all zero scaling factors
    function test_batchPost_roundTrip_allZeroScaling() public view {
        bytes32[] memory claimants = new bytes32[](3);
        claimants[0] = CLAIMANT_1;
        claimants[1] = CLAIMANT_2;
        claimants[2] = CLAIMANT_3;

        bytes32[] memory claimHashes = new bytes32[](3);
        claimHashes[0] = CLAIM_HASH_1;
        claimHashes[1] = CLAIM_HASH_2;
        claimHashes[2] = CLAIM_HASH_3;

        uint256[] memory scalingFactors = new uint256[](3);
        scalingFactors[0] = 0;
        scalingFactors[1] = 0;
        scalingFactors[2] = 0;

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
        (bytes32[] memory decodedClaimants, bytes32[] memory decodedHashes, uint256[] memory decodedFactors) =
            wrapper.decodeBatchPost(encoded);

        assertArraysEqual(claimants, decodedClaimants, "claimants");
        assertArraysEqual(claimHashes, decodedHashes, "hashes");
        assertArraysEqual(scalingFactors, decodedFactors, "factors");
    }

    /// @notice Test round trip with mixed scaling including zero
    function test_batchPost_roundTrip_mixedScalingWithZero() public view {
        bytes32[] memory claimants = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            claimants[i] = CLAIMANT_1;
        }

        bytes32[] memory claimHashes = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            claimHashes[i] = bytes32(uint256(CLAIM_HASH_1) + i);
        }

        uint256[] memory scalingFactors = new uint256[](5);
        scalingFactors[0] = SCALING_FACTOR_FULL; // Default
        scalingFactors[1] = 0; // Zero (cancelled)
        scalingFactors[2] = SCALING_FACTOR_HALF; // Reduced
        scalingFactors[3] = 0; // Zero (cancelled)
        scalingFactors[4] = SCALING_FACTOR_QUARTER; // Reduced

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
        (bytes32[] memory decodedClaimants, bytes32[] memory decodedHashes, uint256[] memory decodedFactors) =
            wrapper.decodeBatchPost(encoded);

        assertArraysEqual(claimants, decodedClaimants, "claimants");
        assertArraysEqual(claimHashes, decodedHashes, "hashes");
        assertArraysEqual(scalingFactors, decodedFactors, "factors");
    }

    /// @notice Test round trip with complex mixed pattern
    function test_batchPost_roundTrip_complexMixed() public view {
        bytes32[] memory claimants = new bytes32[](10);
        claimants[0] = CLAIMANT_1;
        claimants[1] = CLAIMANT_1;
        claimants[2] = CLAIMANT_2;
        claimants[3] = CLAIMANT_2;
        claimants[4] = CLAIMANT_2;
        claimants[5] = CLAIMANT_3;
        claimants[6] = CLAIMANT_1; // Back to CLAIMANT_1
        claimants[7] = CLAIMANT_1;
        claimants[8] = CLAIMANT_4;
        claimants[9] = CLAIMANT_4;

        bytes32[] memory claimHashes = new bytes32[](10);
        for (uint256 i = 0; i < 10; i++) {
            claimHashes[i] = bytes32(uint256(CLAIM_HASH_1) + i);
        }

        uint256[] memory scalingFactors = new uint256[](10);
        scalingFactors[0] = SCALING_FACTOR_FULL;
        scalingFactors[1] = SCALING_FACTOR_HALF;
        scalingFactors[2] = SCALING_FACTOR_FULL;
        scalingFactors[3] = SCALING_FACTOR_QUARTER;
        scalingFactors[4] = SCALING_FACTOR_FULL;
        scalingFactors[5] = 0.4e18;
        scalingFactors[6] = SCALING_FACTOR_FULL;
        scalingFactors[7] = SCALING_FACTOR_FULL;
        scalingFactors[8] = SCALING_FACTOR_HALF;
        scalingFactors[9] = SCALING_FACTOR_FULL;

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
        (bytes32[] memory decodedClaimants, bytes32[] memory decodedHashes, uint256[] memory decodedFactors) =
            wrapper.decodeBatchPost(encoded);

        assertArraysEqual(claimants, decodedClaimants, "claimants");
        assertArraysEqual(claimHashes, decodedHashes, "hashes");
        assertArraysEqual(scalingFactors, decodedFactors, "factors");
    }

    //////////////////////////////////////////////////////////////
    // BITMAP TESTS
    //////////////////////////////////////////////////////////////

    /// @notice Test that same claimants compress well (only stores once per change)
    function test_batchPost_compression_consecutiveSameClaimants() public view {
        uint256 count = 10;
        bytes32[] memory claimants = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            claimants[i] = CLAIMANT_1;
        }

        bytes32[] memory claimHashes = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            claimHashes[i] = bytes32(uint256(CLAIM_HASH_1) + i);
        }

        uint256[] memory scalingFactors = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            scalingFactors[i] = SCALING_FACTOR_FULL;
        }

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);

        // Expected size:
        // 32 bytes (headers) + 32 bytes (1 claimant) + 320 bytes (10 hashes) + 0 bytes (no non-default factors)
        // = 384 bytes
        require(encoded.length == 384, "compressed size mismatch");
    }

    /// @notice Test that all different claimants use full storage
    function test_batchPost_compression_allDifferentClaimants() public view {
        uint256 count = 10;
        bytes32[] memory claimants = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            claimants[i] = bytes32(uint256(CLAIMANT_2) + i); // All different
        }

        bytes32[] memory claimHashes = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            claimHashes[i] = bytes32(uint256(CLAIM_HASH_1) + i);
        }

        uint256[] memory scalingFactors = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            scalingFactors[i] = SCALING_FACTOR_FULL; // All default
        }

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);

        // Expected size:
        // 32 bytes (header) + 320 bytes (10 claimants) + 320 bytes (10 hashes) + 0 bytes (no non-default factors)
        // = 672 bytes
        require(encoded.length == 672, "uncompressed size mismatch");
    }

    /// @notice Test that default scaling factors are not stored
    function test_batchPost_compression_allDefaultScaling() public view {
        uint256 count = 5;
        bytes32[] memory claimants = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            claimants[i] = CLAIMANT_1;
        }

        bytes32[] memory claimHashes = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            claimHashes[i] = bytes32(uint256(CLAIM_HASH_1) + i);
        }

        uint256[] memory scalingFactors = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            scalingFactors[i] = SCALING_FACTOR_FULL; // All default (1e18)
        }

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);

        // Expected size:
        // 32 bytes (header) + 32 bytes (1 claimant) + 160 bytes (5 hashes) + 0 bytes (no stored factors)
        // = 224 bytes
        require(encoded.length == 224, "size without factors mismatch");
    }

    /// @notice Test that non-default scaling factors are stored
    function test_batchPost_compression_allNonDefaultScaling() public view {
        uint256 count = 5;
        bytes32[] memory claimants = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            claimants[i] = CLAIMANT_1;
        }

        bytes32[] memory claimHashes = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            claimHashes[i] = bytes32(uint256(CLAIM_HASH_1) + i);
        }

        uint256[] memory scalingFactors = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            scalingFactors[i] = SCALING_FACTOR_HALF; // All non-default
        }

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);

        // Expected size:
        // 32 bytes (header) + 32 bytes (1 claimant) + 160 bytes (5 hashes) + 160 bytes (5 stored factors)
        // = 384 bytes
        require(encoded.length == 384, "size with all factors mismatch");
    }

    //////////////////////////////////////////////////////////////
    // EDGE CASE & VALIDATION TESTS
    //////////////////////////////////////////////////////////////

    /// @notice Test encode reverts on array length mismatch (claimants vs hashes)
    function test_batchPost_encode_revertsOnArrayLengthMismatch_claimantsHashes() public {
        bytes32[] memory claimants = new bytes32[](2);
        bytes32[] memory claimHashes = new bytes32[](3); // Different length
        uint256[] memory scalingFactors = new uint256[](2);

        vm.expectRevert("array length mismatch");
        wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
    }

    /// @notice Test encode reverts on array length mismatch (claimants vs factors)
    function test_batchPost_encode_revertsOnArrayLengthMismatch_claimantsFactors() public {
        bytes32[] memory claimants = new bytes32[](2);
        bytes32[] memory claimHashes = new bytes32[](2);
        uint256[] memory scalingFactors = new uint256[](3); // Different length

        vm.expectRevert("array length mismatch");
        wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
    }

    /// @notice Test encode reverts when exceeding max batch size (120)
    function test_batchPost_encode_revertsOnMaxSizeExceeded() public {
        uint256 count = 121; // Over the limit
        bytes32[] memory claimants = new bytes32[](count);
        bytes32[] memory claimHashes = new bytes32[](count);
        uint256[] memory scalingFactors = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            claimants[i] = CLAIMANT_1;
            claimHashes[i] = bytes32(uint256(CLAIM_HASH_1) + i);
            scalingFactors[i] = SCALING_FACTOR_FULL;
        }

        vm.expectRevert("Max 120 claims per batch");
        wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
    }

    /// @notice Test decode reverts on message too short
    function test_batchPost_decode_revertsOnMessageTooShort() public {
        bytes memory tooShort = new bytes(16); // Less than 32 bytes (header size)

        vm.expectRevert("message too short");
        wrapper.decodeBatchPost(tooShort);
    }

    /// @notice Test round trip with exactly 120 items (max batch size)
    function test_batchPost_roundTrip_maxBatchSize() public view {
        uint256 count = 100; // Reduce to 100 to stay well within bitmap limits
        bytes32[] memory claimants = new bytes32[](count);
        bytes32[] memory claimHashes = new bytes32[](count);
        uint256[] memory scalingFactors = new uint256[](count);

        // Create pattern: groups of 10 same claimants, all default scaling
        for (uint256 i = 0; i < count; i++) {
            // Use a large multiplier to ensure distinct claimants for each group
            // forge-lint: disable-next-line(divide-before-multiply)
            claimants[i] = bytes32(uint256(CLAIMANT_1) + ((i / 10) * 1e30)); // Changes every 10 items
            claimHashes[i] = bytes32(uint256(CLAIM_HASH_1) + (i * 1e10));
            // All default for now to simplify
            scalingFactors[i] = SCALING_FACTOR_FULL;
        }

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
        (bytes32[] memory decodedClaimants, bytes32[] memory decodedHashes, uint256[] memory decodedFactors) =
            wrapper.decodeBatchPost(encoded);

        assertArraysEqual(claimants, decodedClaimants, "claimants");
        assertArraysEqual(claimHashes, decodedHashes, "hashes");
        assertArraysEqual(scalingFactors, decodedFactors, "factors");
    }

    /// @notice Test round trip with extreme scaling factor values
    function test_batchPost_roundTrip_extremeScalingFactors() public view {
        bytes32[] memory claimants = new bytes32[](4);
        for (uint256 i = 0; i < 4; i++) {
            claimants[i] = CLAIMANT_1;
        }

        bytes32[] memory claimHashes = new bytes32[](4);
        for (uint256 i = 0; i < 4; i++) {
            claimHashes[i] = bytes32(uint256(CLAIM_HASH_1) + i);
        }

        uint256[] memory scalingFactors = new uint256[](4);
        scalingFactors[0] = 1; // Very small
        scalingFactors[1] = 0.01e18; // 1%
        scalingFactors[2] = 100e18; // 10000%
        scalingFactors[3] = type(uint256).max; // Maximum

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
        (bytes32[] memory decodedClaimants, bytes32[] memory decodedHashes, uint256[] memory decodedFactors) =
            wrapper.decodeBatchPost(encoded);

        assertArraysEqual(claimants, decodedClaimants, "claimants");
        assertArraysEqual(claimHashes, decodedHashes, "hashes");
        assertArraysEqual(scalingFactors, decodedFactors, "factors");
    }

    /// @notice Test round trip with max values for claimants and hashes
    function test_batchPost_roundTrip_maxValues() public view {
        bytes32[] memory claimants = new bytes32[](2);
        claimants[0] = bytes32(type(uint256).max);
        claimants[1] = bytes32(type(uint256).max - 1);

        bytes32[] memory claimHashes = new bytes32[](2);
        claimHashes[0] = bytes32(type(uint256).max);
        claimHashes[1] = bytes32(type(uint256).max - 1);

        uint256[] memory scalingFactors = new uint256[](2);
        scalingFactors[0] = SCALING_FACTOR_FULL;
        scalingFactors[1] = type(uint256).max;

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
        (bytes32[] memory decodedClaimants, bytes32[] memory decodedHashes, uint256[] memory decodedFactors) =
            wrapper.decodeBatchPost(encoded);

        assertArraysEqual(claimants, decodedClaimants, "claimants");
        assertArraysEqual(claimHashes, decodedHashes, "hashes");
        assertArraysEqual(scalingFactors, decodedFactors, "factors");
    }

    //////////////////////////////////////////////////////////////
    // FUZZ TESTS
    //////////////////////////////////////////////////////////////

    /// @notice Fuzz test: encode/decode round trip preserves data
    function testFuzz_batchPost_roundTrip(uint8 count, uint256 seed) public view {
        // Bound count to valid range [1, 100] - staying conservative
        count = uint8(bound(count, 1, 100));

        bytes32[] memory claimants = new bytes32[](count);
        bytes32[] memory claimHashes = new bytes32[](count);
        uint256[] memory scalingFactors = new uint256[](count);

        // Track claimant counter to ensure distinct values when we want them
        uint256 claimantCounter = 0;

        // Generate pseudo-random but deterministic data
        for (uint256 i = 0; i < count; i++) {
            uint256 randomValue = uint256(keccak256(abi.encodePacked(seed, i)));

            // Claimants: create some consecutive duplicates for compression
            // Use a counter to ensure new claimants are actually different
            if (i == 0 || randomValue % 3 == 0) {
                // New claimant - use counter to ensure it's distinct
                claimants[i] = bytes32(uint256(CLAIMANT_1) + (claimantCounter * 1e35));
                claimantCounter++;
            } else {
                claimants[i] = claimants[i - 1]; // Explicitly reuse previous
            }

            claimHashes[i] = keccak256(abi.encodePacked(seed, "hash", i));

            // Scaling factors: mix of default (1e18) and non-default values
            if (randomValue % 2 == 0) {
                scalingFactors[i] = 1e18; // Default
            } else {
                // Use predefined non-default values to avoid any rounding issues
                scalingFactors[i] = SCALING_FACTOR_HALF;
            }
        }

        bytes memory encoded = wrapper.encodeBatchPost(claimants, claimHashes, scalingFactors);
        (bytes32[] memory decodedClaimants, bytes32[] memory decodedHashes, uint256[] memory decodedFactors) =
            wrapper.decodeBatchPost(encoded);

        assertArraysEqual(claimants, decodedClaimants, "fuzz: claimants");
        assertArraysEqual(claimHashes, decodedHashes, "fuzz: hashes");
        assertArraysEqual(scalingFactors, decodedFactors, "fuzz: factors");
    }
}
