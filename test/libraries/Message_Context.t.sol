// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Message} from "../../src/libraries/Message.sol";
import {WormholeParams} from "../../src/wormhole/WormholeTypes.sol";

/// @title MessageContextWrapper
/// @notice Wrapper contract to call Message context functions in tests
/// @dev Needed because library functions use calldata parameters
contract MessageContextWrapper {
    function encodeSendContext(
        bytes calldata allocatorData,
        bytes calldata sponsorSignature,
        WormholeParams memory params,
        bytes calldata signedQuote
    ) external pure returns (bytes memory) {
        return Message.encodeSendContext(allocatorData, sponsorSignature, params, signedQuote);
    }

    function decodeSendContext(bytes calldata context)
        external
        pure
        returns (
            bytes calldata allocatorData,
            bytes calldata sponsorSignature,
            WormholeParams memory params,
            bytes calldata signedQuote
        )
    {
        return Message.decodeSendContext(context);
    }

    function encodePostContext(bytes calldata allocatorData, bytes calldata sponsorSignature)
        external
        pure
        returns (bytes memory)
    {
        return Message.encodePostContext(allocatorData, sponsorSignature);
    }

    function decodePostContext(bytes calldata context)
        external
        pure
        returns (bytes calldata allocatorData, bytes calldata sponsorSignature)
    {
        return Message.decodePostContext(context);
    }
}

/// @title MessageContextTest
/// @notice Comprehensive test suite for Message context encoding/decoding functions
/// @dev Tests encodeSendContext, decodeSendContext, encodePostContext, and decodePostContext
contract MessageContextTest is Test {
    MessageContextWrapper public wrapper;

    // Mock Signatures (64 bytes each)
    bytes constant SPONSOR_SIG = hex"1111111111111111111111111111111111111111111111111111111111111111"
        hex"2222222222222222222222222222222222222222222222222222222222222222";
    bytes constant ALLOCATOR_SIG = hex"3333333333333333333333333333333333333333333333333333333333333333"
        hex"4444444444444444444444444444444444444444444444444444444444444444";

    // Mock WormholeParams
    uint128 constant GAS_LIMIT = 500_000;
    uint256 constant TOTAL_COST = 1 ether;

    // Mock signed quote
    bytes constant SIGNED_QUOTE =
        hex"aabbccdd11223344556677889900aabbccdd11223344556677889900aabbccdd";

    function createWormholeParams(uint128 gasLimit, uint256 totalCost)
        internal
        pure
        returns (WormholeParams memory)
    {
        return WormholeParams({gasLimit: gasLimit, totalCost: totalCost});
    }

    function assertWormholeParamsEqual(WormholeParams memory expected, WormholeParams memory actual)
        internal
        pure
    {
        require(expected.gasLimit == actual.gasLimit, "gasLimit mismatch");
        require(expected.totalCost == actual.totalCost, "totalCost mismatch");
    }

    function setUp() public {
        wrapper = new MessageContextWrapper();
    }

    //////////////////////////////////////////////////////////////
    // SEND CONTEXT TESTS
    //////////////////////////////////////////////////////////////

    /// @notice Test encodeSendContext reverts with invalid allocator signature length
    function test_encodeSendContext_revertsOnAllocatorDataTooLong() public {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);

        vm.expectRevert("allocator data too long");
        bytes memory tooLong = new bytes(65536);
        wrapper.encodeSendContext(tooLong, hex"", params, SIGNED_QUOTE);
    }

    /// @notice Test encodeSendContext reverts with sponsor signature exceeding uint16 max
    function test_encodeSendContext_revertsOnSponsorSignatureTooLong() public {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);

        vm.expectRevert("sponsor signature too long");
        bytes memory tooLong = new bytes(65536);
        wrapper.encodeSendContext(hex"", tooLong, params, SIGNED_QUOTE);
    }

    /// @notice Test round trip with both signatures present
    function test_sendContext_roundTrip_bothSignatures() public view {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);

        bytes memory encoded = wrapper.encodeSendContext(ALLOCATOR_SIG, SPONSOR_SIG, params, SIGNED_QUOTE);

        (
            bytes memory decodedAllocator,
            bytes memory decodedSponsor,
            WormholeParams memory decodedParams,
            bytes memory decodedQuote
        ) = wrapper.decodeSendContext(encoded);

        assertEq(keccak256(decodedAllocator), keccak256(ALLOCATOR_SIG), "allocator data mismatch");
        assertEq(keccak256(decodedSponsor), keccak256(SPONSOR_SIG), "sponsor signature mismatch");
        assertWormholeParamsEqual(params, decodedParams);
        assertEq(keccak256(decodedQuote), keccak256(SIGNED_QUOTE), "signed quote mismatch");
    }

    /// @notice Test round trip with zero signatures
    function test_sendContext_roundTrip_zeroSignatures() public view {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);

        bytes memory encoded = wrapper.encodeSendContext(hex"", hex"", params, SIGNED_QUOTE);

        (
            bytes memory decodedAllocator,
            bytes memory decodedSponsor,
            WormholeParams memory decodedParams,
            bytes memory decodedQuote
        ) = wrapper.decodeSendContext(encoded);

        assertEq(decodedAllocator.length, 0, "allocator data should be empty");
        assertEq(decodedSponsor.length, 0, "sponsor signature should be empty");
        assertWormholeParamsEqual(params, decodedParams);
        assertEq(keccak256(decodedQuote), keccak256(SIGNED_QUOTE), "signed quote mismatch");
    }

    /// @notice Test round trip with only allocator signature
    function test_sendContext_roundTrip_onlyAllocatorSignature() public view {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);

        bytes memory encoded = wrapper.encodeSendContext(ALLOCATOR_SIG, hex"", params, SIGNED_QUOTE);

        (
            bytes memory decodedAllocator,
            bytes memory decodedSponsor,
            WormholeParams memory decodedParams,
            bytes memory decodedQuote
        ) = wrapper.decodeSendContext(encoded);

        assertEq(keccak256(decodedAllocator), keccak256(ALLOCATOR_SIG), "allocator data mismatch");
        assertEq(decodedSponsor.length, 0, "sponsor signature should be empty");
        assertWormholeParamsEqual(params, decodedParams);
        assertEq(keccak256(decodedQuote), keccak256(SIGNED_QUOTE), "signed quote mismatch");
    }

    /// @notice Test round trip with only sponsor signature
    function test_sendContext_roundTrip_onlySponsorSignature() public view {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);

        bytes memory encoded = wrapper.encodeSendContext(hex"", SPONSOR_SIG, params, SIGNED_QUOTE);

        (
            bytes memory decodedAllocator,
            bytes memory decodedSponsor,
            WormholeParams memory decodedParams,
            bytes memory decodedQuote
        ) = wrapper.decodeSendContext(encoded);

        assertEq(decodedAllocator.length, 0, "allocator data should be empty");
        assertEq(keccak256(decodedSponsor), keccak256(SPONSOR_SIG), "sponsor signature mismatch");
        assertWormholeParamsEqual(params, decodedParams);
        assertEq(keccak256(decodedQuote), keccak256(SIGNED_QUOTE), "signed quote mismatch");
    }

    /// @notice Test round trip with empty signed quote
    function test_sendContext_roundTrip_emptySignedQuote() public view {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);

        bytes memory encoded = wrapper.encodeSendContext(ALLOCATOR_SIG, SPONSOR_SIG, params, hex"");

        (
            bytes memory decodedAllocator,
            bytes memory decodedSponsor,
            WormholeParams memory decodedParams,
            bytes memory decodedQuote
        ) = wrapper.decodeSendContext(encoded);

        assertEq(keccak256(decodedAllocator), keccak256(ALLOCATOR_SIG), "allocator data mismatch");
        assertEq(keccak256(decodedSponsor), keccak256(SPONSOR_SIG), "sponsor signature mismatch");
        assertWormholeParamsEqual(params, decodedParams);
        assertEq(decodedQuote.length, 0, "signed quote should be empty");
    }

    /// @notice Test round trip with large signed quote
    function test_sendContext_roundTrip_largeSignedQuote() public view {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);
        bytes memory largeQuote = new bytes(1024);
        for (uint256 i = 0; i < 1024; i++) {
            largeQuote[i] = bytes1(uint8(i % 256));
        }

        bytes memory encoded = wrapper.encodeSendContext(ALLOCATOR_SIG, SPONSOR_SIG, params, largeQuote);

        (
            bytes memory decodedAllocator,
            bytes memory decodedSponsor,
            WormholeParams memory decodedParams,
            bytes memory decodedQuote
        ) = wrapper.decodeSendContext(encoded);

        assertEq(keccak256(decodedAllocator), keccak256(ALLOCATOR_SIG), "allocator data mismatch");
        assertEq(keccak256(decodedSponsor), keccak256(SPONSOR_SIG), "sponsor signature mismatch");
        assertWormholeParamsEqual(params, decodedParams);
        assertEq(keccak256(decodedQuote), keccak256(largeQuote), "signed quote mismatch");
    }

    /// @notice Test round trip with extreme gas limit and total cost values
    function test_sendContext_roundTrip_extremeValues() public view {
        WormholeParams memory params = createWormholeParams(type(uint128).max, type(uint256).max);

        bytes memory encoded = wrapper.encodeSendContext(ALLOCATOR_SIG, SPONSOR_SIG, params, SIGNED_QUOTE);

        (
            bytes memory decodedAllocator,
            bytes memory decodedSponsor,
            WormholeParams memory decodedParams,
            bytes memory decodedQuote
        ) = wrapper.decodeSendContext(encoded);

        assertEq(keccak256(decodedAllocator), keccak256(ALLOCATOR_SIG), "allocator data mismatch");
        assertEq(keccak256(decodedSponsor), keccak256(SPONSOR_SIG), "sponsor signature mismatch");
        assertWormholeParamsEqual(params, decodedParams);
        assertEq(keccak256(decodedQuote), keccak256(SIGNED_QUOTE), "signed quote mismatch");
    }

    /// @notice Test decodeSendContext reverts on context too short (minimum 49 bytes)
    function test_decodeSendContext_revertsOnContextTooShort() public {
        bytes memory tooShort = new bytes(48);

        vm.expectRevert("context too short");
        wrapper.decodeSendContext(tooShort);
    }


    /// @notice Fuzz test: encodeSendContext/decodeSendContext round trip
    function testFuzz_sendContext_roundTrip(
        bool hasAllocatorSig,
        bool hasSponsorSig,
        uint128 gasLimit,
        uint256 totalCost,
        uint16 quoteLength
    ) public view {
        // Bound quote length to reasonable size
        quoteLength = uint16(bound(quoteLength, 0, 2048));

        // Create inputs
        bytes memory allocatorData = hasAllocatorSig ? ALLOCATOR_SIG : new bytes(0);
        bytes memory sponsorSig = hasSponsorSig ? SPONSOR_SIG : new bytes(0);
        WormholeParams memory params = createWormholeParams(gasLimit, totalCost);
        bytes memory signedQuote = new bytes(quoteLength);

        // Encode
        bytes memory encoded = wrapper.encodeSendContext(allocatorData, sponsorSig, params, signedQuote);

        // Decode
        (
            bytes memory decodedAllocator,
            bytes memory decodedSponsor,
            WormholeParams memory decodedParams,
            bytes memory decodedQuote
        ) = wrapper.decodeSendContext(encoded);

        // Assert all fields match
        assertEq(keccak256(decodedAllocator), keccak256(allocatorData), "allocator data mismatch");
        assertEq(keccak256(decodedSponsor), keccak256(sponsorSig), "sponsor signature mismatch");
        assertWormholeParamsEqual(params, decodedParams);
        assertEq(keccak256(decodedQuote), keccak256(signedQuote), "signed quote mismatch");
    }

    //////////////////////////////////////////////////////////////
    // POST CONTEXT TESTS
    //////////////////////////////////////////////////////////////

    /// @notice Test encodePostContext reverts with invalid allocator signature length
    function test_encodePostContext_revertsOnAllocatorDataTooLong() public {
        vm.expectRevert("allocator data too long");
        bytes memory tooLong = new bytes(65536);
        wrapper.encodePostContext(tooLong, hex"");
    }

    /// @notice Test encodePostContext reverts with sponsor signature exceeding uint16 max
    function test_encodePostContext_revertsOnSponsorSignatureTooLong() public {
        vm.expectRevert("sponsor signature too long");
        bytes memory tooLong = new bytes(65536);
        wrapper.encodePostContext(hex"", tooLong);
    }

    /// @notice Test round trip with both signatures present
    function test_postContext_roundTrip_bothSignatures() public view {
        bytes memory encoded = wrapper.encodePostContext(ALLOCATOR_SIG, SPONSOR_SIG);

        (bytes memory decodedAllocator, bytes memory decodedSponsor) = wrapper.decodePostContext(encoded);

        assertEq(keccak256(decodedAllocator), keccak256(ALLOCATOR_SIG), "allocator data mismatch");
        assertEq(keccak256(decodedSponsor), keccak256(SPONSOR_SIG), "sponsor signature mismatch");
    }

    /// @notice Test round trip with zero signatures
    function test_postContext_roundTrip_zeroSignatures() public view {
        bytes memory encoded = wrapper.encodePostContext(hex"", hex"");

        (bytes memory decodedAllocator, bytes memory decodedSponsor) = wrapper.decodePostContext(encoded);

        assertEq(decodedAllocator.length, 0, "allocator data should be empty");
        assertEq(decodedSponsor.length, 0, "sponsor signature should be empty");
    }

    /// @notice Test round trip with only allocator signature
    function test_postContext_roundTrip_onlyAllocatorSignature() public view {
        bytes memory encoded = wrapper.encodePostContext(ALLOCATOR_SIG, hex"");

        (bytes memory decodedAllocator, bytes memory decodedSponsor) = wrapper.decodePostContext(encoded);

        assertEq(keccak256(decodedAllocator), keccak256(ALLOCATOR_SIG), "allocator data mismatch");
        assertEq(decodedSponsor.length, 0, "sponsor signature should be empty");
    }

    /// @notice Test round trip with only sponsor signature
    function test_postContext_roundTrip_onlySponsorSignature() public view {
        bytes memory encoded = wrapper.encodePostContext(hex"", SPONSOR_SIG);

        (bytes memory decodedAllocator, bytes memory decodedSponsor) = wrapper.decodePostContext(encoded);

        assertEq(decodedAllocator.length, 0, "allocator data should be empty");
        assertEq(keccak256(decodedSponsor), keccak256(SPONSOR_SIG), "sponsor signature mismatch");
    }

    /// @notice Test decodePostContext reverts on context too short
    function test_decodePostContext_revertsOnContextTooShort() public {
        bytes memory tooShort = new bytes(0);

        vm.expectRevert("context too short");
        wrapper.decodePostContext(tooShort);
    }

    /// @notice Test decodePostContext reverts on unexpected trailing data
    function test_decodePostContext_revertsOnTrailingData() public {
        // Create a valid context with both signatures
        bytes memory validEncoded = wrapper.encodePostContext(ALLOCATOR_SIG, SPONSOR_SIG);

        // Add trailing bytes
        bytes memory withTrailing = new bytes(validEncoded.length + 10);
        for (uint256 i = 0; i < validEncoded.length; i++) {
            withTrailing[i] = validEncoded[i];
        }

        vm.expectRevert("context has unexpected trailing data");
        wrapper.decodePostContext(withTrailing);
    }

    /// @notice Fuzz test: encodePostContext/decodePostContext round trip
    function testFuzz_postContext_roundTrip(bool hasAllocatorSig, bool hasSponsorSig) public view {
        // Create inputs
        bytes memory allocatorData = hasAllocatorSig ? ALLOCATOR_SIG : new bytes(0);
        bytes memory sponsorSig = hasSponsorSig ? SPONSOR_SIG : new bytes(0);

        // Encode
        bytes memory encoded = wrapper.encodePostContext(allocatorData, sponsorSig);

        // Decode
        (bytes memory decodedAllocator, bytes memory decodedSponsor) = wrapper.decodePostContext(encoded);

        // Assert all fields match
        assertEq(keccak256(decodedAllocator), keccak256(allocatorData), "allocator data mismatch");
        assertEq(keccak256(decodedSponsor), keccak256(sponsorSig), "sponsor signature mismatch");
    }

    //////////////////////////////////////////////////////////////
    // FLAG VERIFICATION TESTS
    //////////////////////////////////////////////////////////////

    /// @notice Test that IS_SEND flag is set in send context encoding
    function test_sendContext_isSendFlagIsSet() public view {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);
        bytes memory encoded = wrapper.encodeSendContext(hex"", hex"", params, SIGNED_QUOTE);

        // IS_SEND flag is 0x04
        uint8 flags = uint8(encoded[0]);
        assertEq(flags & 0x04, 0x04, "IS_SEND flag should be set");
    }

    /// @notice Test that IS_SEND flag is NOT set in post context encoding
    function test_postContext_isSendFlagIsNotSet() public view {
        bytes memory encoded = wrapper.encodePostContext(hex"", hex"");

        // IS_SEND flag is 0x04
        uint8 flags = uint8(encoded[0]);
        assertEq(flags & 0x04, 0x00, "IS_SEND flag should NOT be set");
    }

    /// @notice Test flag combinations for send context
    function test_sendContext_flagCombinations() public view {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);

        // No signatures: only IS_SEND (0x04)
        bytes memory encoded1 = wrapper.encodeSendContext(hex"", hex"", params, SIGNED_QUOTE);
        assertEq(uint8(encoded1[0]), 0x04, "flags should be 0x04 (IS_SEND only)");

        // Only allocator: HAS_ALLOCATOR_SIG (0x01) | IS_SEND (0x04) = 0x05
        bytes memory encoded2 = wrapper.encodeSendContext(ALLOCATOR_SIG, hex"", params, SIGNED_QUOTE);
        assertEq(uint8(encoded2[0]), 0x05, "flags should be 0x05");

        // Only sponsor: HAS_SPONSOR_SIG (0x02) | IS_SEND (0x04) = 0x06
        bytes memory encoded3 = wrapper.encodeSendContext(hex"", SPONSOR_SIG, params, SIGNED_QUOTE);
        assertEq(uint8(encoded3[0]), 0x06, "flags should be 0x06");

        // Both signatures: HAS_ALLOCATOR_SIG (0x01) | HAS_SPONSOR_SIG (0x02) | IS_SEND (0x04) = 0x07
        bytes memory encoded4 = wrapper.encodeSendContext(ALLOCATOR_SIG, SPONSOR_SIG, params, SIGNED_QUOTE);
        assertEq(uint8(encoded4[0]), 0x07, "flags should be 0x07");
    }

    /// @notice Test flag combinations for post context
    function test_postContext_flagCombinations() public view {
        // No signatures: 0x00
        bytes memory encoded1 = wrapper.encodePostContext(hex"", hex"");
        assertEq(uint8(encoded1[0]), 0x00, "flags should be 0x00");

        // Only allocator: HAS_ALLOCATOR_SIG (0x01)
        bytes memory encoded2 = wrapper.encodePostContext(ALLOCATOR_SIG, hex"");
        assertEq(uint8(encoded2[0]), 0x01, "flags should be 0x01");

        // Only sponsor: HAS_SPONSOR_SIG (0x02)
        bytes memory encoded3 = wrapper.encodePostContext(hex"", SPONSOR_SIG);
        assertEq(uint8(encoded3[0]), 0x02, "flags should be 0x02");

        // Both signatures: HAS_ALLOCATOR_SIG (0x01) | HAS_SPONSOR_SIG (0x02) = 0x03
        bytes memory encoded4 = wrapper.encodePostContext(ALLOCATOR_SIG, SPONSOR_SIG);
        assertEq(uint8(encoded4[0]), 0x03, "flags should be 0x03");
    }

    //////////////////////////////////////////////////////////////
    // SIZE VERIFICATION TESTS
    //////////////////////////////////////////////////////////////

    /// @notice Test send context encoding produces expected sizes
    function test_sendContext_sizes() public view {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);

        // Minimum size: 1 (flags) + 16 (gasLimit) + 32 (totalCost) = 49 bytes (with empty quote)
        bytes memory encoded1 = wrapper.encodeSendContext(hex"", hex"", params, hex"");
        assertEq(encoded1.length, 49, "minimum size should be 49");

        // With allocator: 49 + 2 (length prefix) + 64 (data) = 115
        bytes memory encoded2 = wrapper.encodeSendContext(ALLOCATOR_SIG, hex"", params, hex"");
        assertEq(encoded2.length, 115, "with allocator should be 115");

        // With sponsor: 49 + 2 (length prefix) + 64 (data) = 115
        bytes memory encoded3 = wrapper.encodeSendContext(hex"", SPONSOR_SIG, params, hex"");
        assertEq(encoded3.length, 115, "with sponsor should be 115");

        // With both: 49 + 2 + 64 + 2 + 64 = 181
        bytes memory encoded4 = wrapper.encodeSendContext(ALLOCATOR_SIG, SPONSOR_SIG, params, hex"");
        assertEq(encoded4.length, 181, "with both should be 181");

        // With both + 32-byte quote: 181 + 32 = 213
        bytes memory encoded5 = wrapper.encodeSendContext(ALLOCATOR_SIG, SPONSOR_SIG, params, SIGNED_QUOTE);
        assertEq(encoded5.length, 213, "with both + quote should be 213");
    }

    /// @notice Test post context encoding produces expected sizes
    function test_postContext_sizes() public view {
        // Minimum size: 1 (flags)
        bytes memory encoded1 = wrapper.encodePostContext(hex"", hex"");
        assertEq(encoded1.length, 1, "minimum size should be 1");

        // With allocator: 1 + 2 (length prefix) + 64 (data) = 67
        bytes memory encoded2 = wrapper.encodePostContext(ALLOCATOR_SIG, hex"");
        assertEq(encoded2.length, 67, "with allocator should be 67");

        // With sponsor: 1 + 2 (length prefix) + 64 (data) = 67
        bytes memory encoded3 = wrapper.encodePostContext(hex"", SPONSOR_SIG);
        assertEq(encoded3.length, 67, "with sponsor should be 67");

        // With both: 1 + 2 + 64 + 2 + 64 = 133
        bytes memory encoded4 = wrapper.encodePostContext(ALLOCATOR_SIG, SPONSOR_SIG);
        assertEq(encoded4.length, 133, "with both should be 133");
    }
}
