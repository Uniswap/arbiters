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
        bytes calldata signedQuote,
        address refundAddress
    ) external pure returns (bytes memory) {
        return Message.encodeSendContext(allocatorData, sponsorSignature, params, signedQuote, refundAddress);
    }

    function decodeSendContext(bytes calldata context)
        external
        pure
        returns (
            bytes calldata allocatorData,
            bytes calldata sponsorSignature,
            WormholeParams memory params,
            bytes calldata signedQuote,
            address refundAddress
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

    // Mock signed quote (68 bytes minimum per Wormhole Executor requirements)
    bytes constant SIGNED_QUOTE = hex"aabbccdd11223344556677889900aabbccdd11223344556677889900aabbccdd"
        hex"aabbccdd11223344556677889900aabbccdd11223344556677889900aabbccdd" hex"aabbccdd";

    // Mock refund address
    address constant REFUND_ADDRESS = address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF);

    function createWormholeParams(uint128 gasLimit, uint256 totalCost) internal pure returns (WormholeParams memory) {
        return WormholeParams({gasLimit: gasLimit, totalCost: totalCost});
    }

    function assertWormholeParamsEqual(WormholeParams memory expected, WormholeParams memory actual) internal pure {
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

        vm.expectRevert(Message.AllocatorDataTooLong.selector);
        bytes memory tooLong = new bytes(65536);
        wrapper.encodeSendContext(tooLong, hex"", params, SIGNED_QUOTE, REFUND_ADDRESS);
    }

    /// @notice Test encodeSendContext reverts with sponsor signature exceeding uint16 max
    function test_encodeSendContext_revertsOnSponsorSignatureTooLong() public {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);

        vm.expectRevert(Message.SponsorSignatureTooLong.selector);
        bytes memory tooLong = new bytes(65536);
        wrapper.encodeSendContext(hex"", tooLong, params, SIGNED_QUOTE, REFUND_ADDRESS);
    }

    /// @notice Test round trip with both signatures present
    function test_sendContext_roundTrip_bothSignatures() public view {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);

        bytes memory encoded =
            wrapper.encodeSendContext(ALLOCATOR_SIG, SPONSOR_SIG, params, SIGNED_QUOTE, REFUND_ADDRESS);

        (
            bytes memory decodedAllocator,
            bytes memory decodedSponsor,
            WormholeParams memory decodedParams,
            bytes memory decodedQuote,
            address decodedRefundAddress
        ) = wrapper.decodeSendContext(encoded);

        assertEq(keccak256(decodedAllocator), keccak256(ALLOCATOR_SIG), "allocator data mismatch");
        assertEq(keccak256(decodedSponsor), keccak256(SPONSOR_SIG), "sponsor signature mismatch");
        assertWormholeParamsEqual(params, decodedParams);
        assertEq(keccak256(decodedQuote), keccak256(SIGNED_QUOTE), "signed quote mismatch");
        assertEq(decodedRefundAddress, REFUND_ADDRESS, "refund address mismatch");
    }

    /// @notice Test round trip with zero signatures
    function test_sendContext_roundTrip_zeroSignatures() public view {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);

        bytes memory encoded = wrapper.encodeSendContext(hex"", hex"", params, SIGNED_QUOTE, REFUND_ADDRESS);

        (
            bytes memory decodedAllocator,
            bytes memory decodedSponsor,
            WormholeParams memory decodedParams,
            bytes memory decodedQuote,
            address decodedRefundAddress
        ) = wrapper.decodeSendContext(encoded);

        assertEq(decodedAllocator.length, 0, "allocator data should be empty");
        assertEq(decodedSponsor.length, 0, "sponsor signature should be empty");
        assertWormholeParamsEqual(params, decodedParams);
        assertEq(keccak256(decodedQuote), keccak256(SIGNED_QUOTE), "signed quote mismatch");
        assertEq(decodedRefundAddress, REFUND_ADDRESS, "refund address mismatch");
    }

    /// @notice Test round trip with only allocator signature
    function test_sendContext_roundTrip_onlyAllocatorSignature() public view {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);

        bytes memory encoded = wrapper.encodeSendContext(ALLOCATOR_SIG, hex"", params, SIGNED_QUOTE, REFUND_ADDRESS);

        (
            bytes memory decodedAllocator,
            bytes memory decodedSponsor,
            WormholeParams memory decodedParams,
            bytes memory decodedQuote,
            address decodedRefundAddress
        ) = wrapper.decodeSendContext(encoded);

        assertEq(keccak256(decodedAllocator), keccak256(ALLOCATOR_SIG), "allocator data mismatch");
        assertEq(decodedSponsor.length, 0, "sponsor signature should be empty");
        assertWormholeParamsEqual(params, decodedParams);
        assertEq(keccak256(decodedQuote), keccak256(SIGNED_QUOTE), "signed quote mismatch");
        assertEq(decodedRefundAddress, REFUND_ADDRESS, "refund address mismatch");
    }

    /// @notice Test round trip with only sponsor signature
    function test_sendContext_roundTrip_onlySponsorSignature() public view {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);

        bytes memory encoded = wrapper.encodeSendContext(hex"", SPONSOR_SIG, params, SIGNED_QUOTE, REFUND_ADDRESS);

        (
            bytes memory decodedAllocator,
            bytes memory decodedSponsor,
            WormholeParams memory decodedParams,
            bytes memory decodedQuote,
            address decodedRefundAddress
        ) = wrapper.decodeSendContext(encoded);

        assertEq(decodedAllocator.length, 0, "allocator data should be empty");
        assertEq(keccak256(decodedSponsor), keccak256(SPONSOR_SIG), "sponsor signature mismatch");
        assertWormholeParamsEqual(params, decodedParams);
        assertEq(keccak256(decodedQuote), keccak256(SIGNED_QUOTE), "signed quote mismatch");
        assertEq(decodedRefundAddress, REFUND_ADDRESS, "refund address mismatch");
    }

    /// @notice Test that empty signed quote reverts
    function test_sendContext_revertsOnSignedQuoteTooShort_empty() public {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);

        vm.expectRevert(Message.SignedQuoteTooShort.selector);
        wrapper.encodeSendContext(ALLOCATOR_SIG, SPONSOR_SIG, params, hex"", REFUND_ADDRESS);
    }

    /// @notice Test that 67-byte signed quote reverts (minimum is 68)
    function test_sendContext_revertsOnSignedQuoteTooShort_67bytes() public {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);
        bytes memory shortQuote = new bytes(67);

        vm.expectRevert(Message.SignedQuoteTooShort.selector);
        wrapper.encodeSendContext(ALLOCATOR_SIG, SPONSOR_SIG, params, shortQuote, REFUND_ADDRESS);
    }

    /// @notice Test that exactly 68-byte signed quote succeeds (minimum length)
    function test_sendContext_roundTrip_minSignedQuote() public view {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);
        bytes memory minQuote = new bytes(68);
        for (uint256 i = 0; i < 68; i++) {
            minQuote[i] = bytes1(uint8(i));
        }

        bytes memory encoded = wrapper.encodeSendContext(ALLOCATOR_SIG, SPONSOR_SIG, params, minQuote, REFUND_ADDRESS);

        (
            bytes memory decodedAllocator,
            bytes memory decodedSponsor,
            WormholeParams memory decodedParams,
            bytes memory decodedQuote,
            address decodedRefundAddress
        ) = wrapper.decodeSendContext(encoded);

        assertEq(keccak256(decodedAllocator), keccak256(ALLOCATOR_SIG), "allocator data mismatch");
        assertEq(keccak256(decodedSponsor), keccak256(SPONSOR_SIG), "sponsor signature mismatch");
        assertWormholeParamsEqual(params, decodedParams);
        assertEq(keccak256(decodedQuote), keccak256(minQuote), "signed quote mismatch");
        assertEq(decodedRefundAddress, REFUND_ADDRESS, "refund address mismatch");
    }

    /// @notice Test round trip with large signed quote
    function test_sendContext_roundTrip_largeSignedQuote() public view {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);
        bytes memory largeQuote = new bytes(1024);
        for (uint256 i = 0; i < 1024; i++) {
            // casting to uint8 is safe because i % 256 is always in range [0, 255]
            // forge-lint: disable-next-line(unsafe-typecast)
            largeQuote[i] = bytes1(uint8(i % 256));
        }

        bytes memory encoded = wrapper.encodeSendContext(ALLOCATOR_SIG, SPONSOR_SIG, params, largeQuote, REFUND_ADDRESS);

        (
            bytes memory decodedAllocator,
            bytes memory decodedSponsor,
            WormholeParams memory decodedParams,
            bytes memory decodedQuote,
            address decodedRefundAddress
        ) = wrapper.decodeSendContext(encoded);

        assertEq(keccak256(decodedAllocator), keccak256(ALLOCATOR_SIG), "allocator data mismatch");
        assertEq(keccak256(decodedSponsor), keccak256(SPONSOR_SIG), "sponsor signature mismatch");
        assertWormholeParamsEqual(params, decodedParams);
        assertEq(keccak256(decodedQuote), keccak256(largeQuote), "signed quote mismatch");
        assertEq(decodedRefundAddress, REFUND_ADDRESS, "refund address mismatch");
    }

    /// @notice Test round trip with extreme gas limit and total cost values
    function test_sendContext_roundTrip_extremeValues() public view {
        WormholeParams memory params = createWormholeParams(type(uint128).max, type(uint256).max);

        bytes memory encoded =
            wrapper.encodeSendContext(ALLOCATOR_SIG, SPONSOR_SIG, params, SIGNED_QUOTE, REFUND_ADDRESS);

        (
            bytes memory decodedAllocator,
            bytes memory decodedSponsor,
            WormholeParams memory decodedParams,
            bytes memory decodedQuote,
            address decodedRefundAddress
        ) = wrapper.decodeSendContext(encoded);

        assertEq(keccak256(decodedAllocator), keccak256(ALLOCATOR_SIG), "allocator data mismatch");
        assertEq(keccak256(decodedSponsor), keccak256(SPONSOR_SIG), "sponsor signature mismatch");
        assertWormholeParamsEqual(params, decodedParams);
        assertEq(keccak256(decodedQuote), keccak256(SIGNED_QUOTE), "signed quote mismatch");
        assertEq(decodedRefundAddress, REFUND_ADDRESS, "refund address mismatch");
    }

    /// @notice Test decodeSendContext reverts on context too short (minimum 69 bytes)
    function test_decodeSendContext_revertsOnContextTooShort() public {
        bytes memory tooShort = new bytes(68);

        vm.expectRevert(Message.ContextTooShort.selector);
        wrapper.decodeSendContext(tooShort);
    }

    /// @notice Test decodeSendContext reverts when signed quote portion is too short
    function test_decodeSendContext_revertsOnSignedQuoteTooShort() public {
        // Minimum valid context needs 137 bytes: flags(1) + gasLimit(16) + totalCost(32) + refundAddress(20) + signedQuote(68)
        // Create a context with 136 bytes (67 bytes for signed quote - one byte short)
        bytes memory shortContext = new bytes(136);
        // Set IS_SEND flag (0x04)
        shortContext[0] = 0x04;

        vm.expectRevert(Message.SignedQuoteTooShort.selector);
        wrapper.decodeSendContext(shortContext);
    }

    /// @notice Test that context with allocator length prefix claiming more bytes than exist reverts
    function test_decodeSendContext_revertsOnContextTooShortForAllocatorSignature() public {
        // Context of minimum length (69 bytes) but allocator claims 1000 bytes
        // Layout: flags(1) + allocLen(2) + remaining(66) - but claims 1000
        bytes memory malformed = new bytes(69);
        malformed[0] = 0x05; // HAS_ALLOCATOR_SIG | IS_SEND
        malformed[1] = 0x03; // High byte of length
        malformed[2] = 0xE8; // Low byte = 0x03E8 = 1000 (claiming 1000 bytes, but only 66 remain)
        vm.expectRevert(Message.ContextTooShortForAllocatorSignature.selector);
        wrapper.decodeSendContext(malformed);
    }

    /// @notice Test that context truncated after allocator data (when sponsor flag set) reverts
    function test_decodeSendContext_revertsOnContextTooShortForSponsorLength() public {
        // Context of minimum length (69 bytes) with allocator consuming most of it
        // flags(1) + allocLen(2) + allocData(64) = 67, leaves only 2 bytes
        // Sponsor flag set but no room for sponsor length prefix
        bytes memory malformed = new bytes(69);
        malformed[0] = 0x07; // HAS_ALLOCATOR_SIG | HAS_SPONSOR_SIG | IS_SEND
        malformed[1] = 0x00;
        malformed[2] = 0x40; // allocator length = 64
        // After reading 64 bytes of allocator data, offset = 1 + 2 + 64 = 67
        // Only 2 bytes remain (69 - 67 = 2), exactly enough for sponsor length check
        // But we need offset + 2 = 69, and context.length = 69, so 69 < 69 is FALSE
        // Let's use 65 bytes of allocator to make offset = 68, then need 2 more = 70 > 69
        malformed[2] = 0x41; // allocator length = 65
        vm.expectRevert(Message.ContextTooShortForSponsorLength.selector);
        wrapper.decodeSendContext(malformed);
    }

    /// @notice Test that context with sponsor length prefix claiming more bytes than exist reverts
    function test_decodeSendContext_revertsOnContextTooShortForSponsorSignature() public {
        // Context with small allocator, but sponsor claims too many bytes
        // flags(1) + allocLen(2) + alloc(10) + sponsorLen(2) = 15 bytes used
        // Remaining 54 bytes, but sponsor claims 100
        bytes memory malformed = new bytes(69);
        malformed[0] = 0x07; // HAS_ALLOCATOR_SIG | HAS_SPONSOR_SIG | IS_SEND
        malformed[1] = 0x00;
        malformed[2] = 0x0A; // allocator length = 10
        // offset after allocator = 1 + 2 + 10 = 13
        malformed[13] = 0x00;
        malformed[14] = 0x64; // sponsor length = 100 (but only 69 - 15 = 54 bytes remain)
        vm.expectRevert(Message.ContextTooShortForSponsorSignature.selector);
        wrapper.decodeSendContext(malformed);
    }

    /// @notice Test that context truncated before WormholeParams reverts
    function test_decodeSendContext_revertsOnContextTooShortForWormholeParams() public {
        // Context with valid signatures but not enough for WormholeParams
        // flags(1) + allocLen(2) + alloc(10) + sponsorLen(2) + sponsor(10) = 25 bytes for sigs
        // Need 68 more for WormholeParams (gasLimit(16) + totalCost(32) + refundAddr(20))
        // So minimum needed = 25 + 68 = 93 bytes, but we provide 69
        bytes memory malformed = new bytes(69);
        malformed[0] = 0x07; // HAS_ALLOCATOR_SIG | HAS_SPONSOR_SIG | IS_SEND
        malformed[1] = 0x00;
        malformed[2] = 0x0A; // allocator length = 10
        // offset after allocator = 13
        malformed[13] = 0x00;
        malformed[14] = 0x0A; // sponsor length = 10
        // offset after sponsor = 25
        // Need 68 more bytes for WormholeParams, but only 69 - 25 = 44 remain
        vm.expectRevert(Message.ContextTooShortForWormholeParams.selector);
        wrapper.decodeSendContext(malformed);
    }

    /// @notice Fuzz test: encodeSendContext/decodeSendContext round trip with variable-length signatures
    function testFuzz_sendContext_roundTrip(
        uint16 allocatorSigLength,
        uint16 sponsorSigLength,
        uint128 gasLimit,
        uint256 totalCost,
        uint16 quoteLength,
        bytes32 randomSeed,
        address refundAddress
    ) public view {
        // Bound lengths to reasonable sizes for testing
        allocatorSigLength = uint16(bound(allocatorSigLength, 0, 2048));
        sponsorSigLength = uint16(bound(sponsorSigLength, 0, 2048));
        // Signed quote minimum is 68 bytes per Wormhole Executor requirements
        quoteLength = uint16(bound(quoteLength, 68, 2048));

        // Create variable-length signatures with pseudo-random data
        bytes memory allocatorData = new bytes(allocatorSigLength);
        bytes memory sponsorSig = new bytes(sponsorSigLength);
        bytes memory signedQuote = new bytes(quoteLength);

        for (uint256 i = 0; i < allocatorSigLength; i++) {
            allocatorData[i] = bytes1(uint8(uint256(keccak256(abi.encode(randomSeed, "allocator", i)))));
        }
        for (uint256 i = 0; i < sponsorSigLength; i++) {
            sponsorSig[i] = bytes1(uint8(uint256(keccak256(abi.encode(randomSeed, "sponsor", i)))));
        }
        for (uint256 i = 0; i < quoteLength; i++) {
            signedQuote[i] = bytes1(uint8(uint256(keccak256(abi.encode(randomSeed, "quote", i)))));
        }

        WormholeParams memory params = createWormholeParams(gasLimit, totalCost);

        // Encode
        bytes memory encoded = wrapper.encodeSendContext(allocatorData, sponsorSig, params, signedQuote, refundAddress);

        // Decode
        (
            bytes memory decodedAllocator,
            bytes memory decodedSponsor,
            WormholeParams memory decodedParams,
            bytes memory decodedQuote,
            address decodedRefundAddress
        ) = wrapper.decodeSendContext(encoded);

        // Assert all fields match
        assertEq(keccak256(decodedAllocator), keccak256(allocatorData), "allocator data mismatch");
        assertEq(keccak256(decodedSponsor), keccak256(sponsorSig), "sponsor signature mismatch");
        assertWormholeParamsEqual(params, decodedParams);
        assertEq(keccak256(decodedQuote), keccak256(signedQuote), "signed quote mismatch");
        assertEq(decodedRefundAddress, refundAddress, "refund address mismatch");
    }

    //////////////////////////////////////////////////////////////
    // POST CONTEXT TESTS
    //////////////////////////////////////////////////////////////

    /// @notice Test encodePostContext reverts with invalid allocator signature length
    function test_encodePostContext_revertsOnAllocatorDataTooLong() public {
        vm.expectRevert(Message.AllocatorDataTooLong.selector);
        bytes memory tooLong = new bytes(65536);
        wrapper.encodePostContext(tooLong, hex"");
    }

    /// @notice Test encodePostContext reverts with sponsor signature exceeding uint16 max
    function test_encodePostContext_revertsOnSponsorSignatureTooLong() public {
        vm.expectRevert(Message.SponsorSignatureTooLong.selector);
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

        vm.expectRevert(Message.ContextTooShort.selector);
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

        vm.expectRevert(Message.ContextHasTrailingData.selector);
        wrapper.decodePostContext(withTrailing);
    }

    /// @notice Test that post context with allocator flag set but truncated before length prefix reverts
    function test_decodePostContext_revertsOnContextTooShortForAllocatorLength() public {
        bytes memory malformed = new bytes(1);
        malformed[0] = 0x01; // HAS_ALLOCATOR_SIG
        vm.expectRevert(Message.ContextTooShortForAllocatorLength.selector);
        wrapper.decodePostContext(malformed);
    }

    /// @notice Test that post context with allocator length prefix claiming more bytes than exist reverts
    function test_decodePostContext_revertsOnContextTooShortForAllocatorSignature() public {
        bytes memory malformed = new bytes(5); // flags(1) + length(2) + 2 bytes (claims 100)
        malformed[0] = 0x01; // HAS_ALLOCATOR_SIG
        malformed[1] = 0x00;
        malformed[2] = 0x64; // length = 100
        vm.expectRevert(Message.ContextTooShortForAllocatorSignature.selector);
        wrapper.decodePostContext(malformed);
    }

    /// @notice Test that post context truncated after allocator data (when sponsor flag set) reverts
    function test_decodePostContext_revertsOnContextTooShortForSponsorLength() public {
        bytes memory malformed = new bytes(13); // flags(1) + allocLen(2) + alloc(10)
        malformed[0] = 0x03; // HAS_ALLOCATOR_SIG | HAS_SPONSOR_SIG
        malformed[1] = 0x00;
        malformed[2] = 0x0A; // allocator length = 10
        for (uint256 i = 0; i < 10; i++) {
            malformed[3 + i] = bytes1(uint8(i));
        }
        vm.expectRevert(Message.ContextTooShortForSponsorLength.selector);
        wrapper.decodePostContext(malformed);
    }

    /// @notice Test that post context with sponsor length prefix claiming more bytes than exist reverts
    function test_decodePostContext_revertsOnContextTooShortForSponsorSignature() public {
        bytes memory malformed = new bytes(17); // flags(1) + allocLen(2) + alloc(10) + sponsorLen(2) + 2 bytes
        malformed[0] = 0x03; // HAS_ALLOCATOR_SIG | HAS_SPONSOR_SIG
        malformed[1] = 0x00;
        malformed[2] = 0x0A; // allocator length = 10
        for (uint256 i = 0; i < 10; i++) {
            malformed[3 + i] = bytes1(uint8(i));
        }
        malformed[13] = 0x00;
        malformed[14] = 0x64; // sponsor length = 100
        vm.expectRevert(Message.ContextTooShortForSponsorSignature.selector);
        wrapper.decodePostContext(malformed);
    }

    /// @notice Fuzz test: encodePostContext/decodePostContext round trip with variable-length signatures
    function testFuzz_postContext_roundTrip(uint16 allocatorSigLength, uint16 sponsorSigLength, bytes32 randomSeed)
        public
        view
    {
        // Bound lengths to reasonable sizes for testing (0 to 2048 bytes)
        // Testing up to uint16.max would be too expensive for fuzzing
        allocatorSigLength = uint16(bound(allocatorSigLength, 0, 2048));
        sponsorSigLength = uint16(bound(sponsorSigLength, 0, 2048));

        // Create variable-length signatures with pseudo-random data
        bytes memory allocatorData = new bytes(allocatorSigLength);
        bytes memory sponsorSig = new bytes(sponsorSigLength);

        for (uint256 i = 0; i < allocatorSigLength; i++) {
            allocatorData[i] = bytes1(uint8(uint256(keccak256(abi.encode(randomSeed, "allocator", i)))));
        }
        for (uint256 i = 0; i < sponsorSigLength; i++) {
            sponsorSig[i] = bytes1(uint8(uint256(keccak256(abi.encode(randomSeed, "sponsor", i)))));
        }

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
        bytes memory encoded = wrapper.encodeSendContext(hex"", hex"", params, SIGNED_QUOTE, REFUND_ADDRESS);

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
        bytes memory encoded1 = wrapper.encodeSendContext(hex"", hex"", params, SIGNED_QUOTE, REFUND_ADDRESS);
        assertEq(uint8(encoded1[0]), 0x04, "flags should be 0x04 (IS_SEND only)");

        // Only allocator: HAS_ALLOCATOR_SIG (0x01) | IS_SEND (0x04) = 0x05
        bytes memory encoded2 = wrapper.encodeSendContext(ALLOCATOR_SIG, hex"", params, SIGNED_QUOTE, REFUND_ADDRESS);
        assertEq(uint8(encoded2[0]), 0x05, "flags should be 0x05");

        // Only sponsor: HAS_SPONSOR_SIG (0x02) | IS_SEND (0x04) = 0x06
        bytes memory encoded3 = wrapper.encodeSendContext(hex"", SPONSOR_SIG, params, SIGNED_QUOTE, REFUND_ADDRESS);
        assertEq(uint8(encoded3[0]), 0x06, "flags should be 0x06");

        // Both signatures: HAS_ALLOCATOR_SIG (0x01) | HAS_SPONSOR_SIG (0x02) | IS_SEND (0x04) = 0x07
        bytes memory encoded4 =
            wrapper.encodeSendContext(ALLOCATOR_SIG, SPONSOR_SIG, params, SIGNED_QUOTE, REFUND_ADDRESS);
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
        bytes memory minQuote = new bytes(68);

        // Minimum size: 1 (flags) + 16 (gasLimit) + 32 (totalCost) + 20 (refundAddress) + 68 (min quote) = 137 bytes
        bytes memory encoded1 = wrapper.encodeSendContext(hex"", hex"", params, minQuote, REFUND_ADDRESS);
        assertEq(encoded1.length, 137, "minimum size should be 137");

        // With allocator: 137 + 2 (length prefix) + 64 (data) = 203
        bytes memory encoded2 = wrapper.encodeSendContext(ALLOCATOR_SIG, hex"", params, minQuote, REFUND_ADDRESS);
        assertEq(encoded2.length, 203, "with allocator should be 203");

        // With sponsor: 137 + 2 (length prefix) + 64 (data) = 203
        bytes memory encoded3 = wrapper.encodeSendContext(hex"", SPONSOR_SIG, params, minQuote, REFUND_ADDRESS);
        assertEq(encoded3.length, 203, "with sponsor should be 203");

        // With both: 137 + 2 + 64 + 2 + 64 = 269
        bytes memory encoded4 = wrapper.encodeSendContext(ALLOCATOR_SIG, SPONSOR_SIG, params, minQuote, REFUND_ADDRESS);
        assertEq(encoded4.length, 269, "with both should be 269");

        // With both + SIGNED_QUOTE (68 bytes): same as above since SIGNED_QUOTE is min length
        bytes memory encoded5 =
            wrapper.encodeSendContext(ALLOCATOR_SIG, SPONSOR_SIG, params, SIGNED_QUOTE, REFUND_ADDRESS);
        assertEq(encoded5.length, 269, "with both + SIGNED_QUOTE should be 269");
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

    //////////////////////////////////////////////////////////////
    // BOUNDARY TESTS
    //////////////////////////////////////////////////////////////

    /// @notice Test encode/decode works at uint16 max boundary for allocator
    function test_sendContext_roundTrip_maxLengthAllocator() public {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);
        bytes memory maxAllocator = new bytes(65535);
        for (uint256 i = 0; i < 65535; i++) {
            maxAllocator[i] = bytes1(uint8(i % 256));
        }
        bytes memory encoded = wrapper.encodeSendContext(maxAllocator, hex"", params, SIGNED_QUOTE, REFUND_ADDRESS);
        (bytes memory decoded,,,,) = wrapper.decodeSendContext(encoded);
        assertEq(keccak256(decoded), keccak256(maxAllocator), "allocator data mismatch");
    }

    /// @notice Test encode/decode works at uint16 max boundary for sponsor
    function test_sendContext_roundTrip_maxLengthSponsor() public {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);
        bytes memory maxSponsor = new bytes(65535);
        for (uint256 i = 0; i < 65535; i++) {
            maxSponsor[i] = bytes1(uint8(i % 256));
        }
        bytes memory encoded = wrapper.encodeSendContext(hex"", maxSponsor, params, SIGNED_QUOTE, REFUND_ADDRESS);
        (, bytes memory decoded,,,) = wrapper.decodeSendContext(encoded);
        assertEq(keccak256(decoded), keccak256(maxSponsor), "sponsor signature mismatch");
    }

    /// @notice Test encode/decode works with both signatures at uint16 max length
    function test_postContext_roundTrip_maxLengthBoth() public {
        bytes memory maxAllocator = new bytes(65535);
        bytes memory maxSponsor = new bytes(65535);
        for (uint256 i = 0; i < 65535; i++) {
            maxAllocator[i] = bytes1(uint8(i % 256));
            maxSponsor[i] = bytes1(uint8((i + 128) % 256));
        }
        bytes memory encoded = wrapper.encodePostContext(maxAllocator, maxSponsor);
        (bytes memory decodedAlloc, bytes memory decodedSponsor) = wrapper.decodePostContext(encoded);
        assertEq(keccak256(decodedAlloc), keccak256(maxAllocator), "allocator data mismatch");
        assertEq(keccak256(decodedSponsor), keccak256(maxSponsor), "sponsor signature mismatch");
    }

    //////////////////////////////////////////////////////////////
    // ZERO VALUE TESTS
    //////////////////////////////////////////////////////////////

    /// @notice Test encode/decode accepts zero gas limit
    function test_sendContext_roundTrip_zeroGasLimit() public view {
        WormholeParams memory params = createWormholeParams(0, TOTAL_COST);
        bytes memory encoded = wrapper.encodeSendContext(hex"", hex"", params, SIGNED_QUOTE, REFUND_ADDRESS);
        (,, WormholeParams memory decodedParams,,) = wrapper.decodeSendContext(encoded);
        assertEq(decodedParams.gasLimit, 0, "gas limit should be zero");
    }

    /// @notice Test encode/decode accepts zero total cost
    function test_sendContext_roundTrip_zeroTotalCost() public view {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, 0);
        bytes memory encoded = wrapper.encodeSendContext(hex"", hex"", params, SIGNED_QUOTE, REFUND_ADDRESS);
        (,, WormholeParams memory decodedParams,,) = wrapper.decodeSendContext(encoded);
        assertEq(decodedParams.totalCost, 0, "total cost should be zero");
    }

    /// @notice Test encode/decode accepts address(0) for refund
    function test_sendContext_roundTrip_zeroRefundAddress() public view {
        WormholeParams memory params = createWormholeParams(GAS_LIMIT, TOTAL_COST);
        bytes memory encoded = wrapper.encodeSendContext(hex"", hex"", params, SIGNED_QUOTE, address(0));
        (,,,, address decodedRefund) = wrapper.decodeSendContext(encoded);
        assertEq(decodedRefund, address(0), "refund address should be zero");
    }
}
