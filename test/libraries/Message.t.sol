// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Message} from "../../src/libraries/Message.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";
import {BatchClaimComponent, Component} from "the-compact/src/types/Components.sol";

/// @title MessageWrapper
/// @notice Wrapper contract to call Message library functions in tests
/// @dev Needed because library functions use calldata parameters

contract MessageWrapper {
    using Message for bytes;

    function encode(
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        bytes32 claimant,
        uint256[] memory claimAmounts
    ) external pure returns (bytes memory) {
        return Message.encode(compact, sponsorSignature, allocatorSignature, mandateHash, claimant, claimAmounts);
    }

    function decode(bytes calldata message)
        external
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
        return message.decode();
    }
}

/// @title MessageTest
/// @notice Comprehensive test suite for the Message library
/// @dev Tests encoding, decoding, and all helper functions
contract MessageTest is Test {
    MessageWrapper public wrapper;

    // BatchCompact
    address constant ARBITER = address(0x1);
    address constant SPONSOR = address(0x2);
    uint256 constant NONCE = 12345;
    uint256 constant EXPIRES = 1234567890;

    // BatchCompact Locks (amounts defined in tests)
    bytes12 constant LOCK_TAG_1 = bytes12(uint96(101));
    bytes12 constant LOCK_TAG_2 = bytes12(uint96(102));
    address constant TOKEN_1 = address(0x3);
    address constant TOKEN_2 = address(0x4);

    // Mock Signatures (64 bytes each)
    bytes constant SPONSOR_SIG = hex"1111111111111111111111111111111111111111111111111111111111111111"
        hex"2222222222222222222222222222222222222222222222222222222222222222";
    bytes constant ALLOCATOR_SIG = hex"3333333333333333333333333333333333333333333333333333333333333333"
        hex"4444444444444444444444444444444444444444444444444444444444444444";

    // Other
    bytes32 constant MANDATE_HASH = keccak256("mandate");
    bytes32 constant CLAIMANT = bytes32(uint256(uint160(address(0x5))));

    function setUp() public {
        wrapper = new MessageWrapper();
    }

    /// @notice Test basic encode with single commitment
    function test_encode_singleCommitment() public view {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: LOCK_TAG_1, token: TOKEN_1, amount: 1000});

        BatchCompact memory compact = BatchCompact({
            arbiter: ARBITER, sponsor: SPONSOR, nonce: NONCE, expires: EXPIRES, commitments: commitments
        });

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = 500;

        bytes memory encoded = wrapper.encode(compact, SPONSOR_SIG, ALLOCATOR_SIG, MANDATE_HASH, CLAIMANT, claimAmounts);

        assertGt(encoded.length, 0, "Encoded message should not be empty");
        // Expected length: 137 (fixed + flags + mandateHash) + 128 (both sigs) + 128 (one claim) = 393 bytes
        assertEq(encoded.length, 393, "Encoded message length should be 393 bytes");

        // Splice the bytecode and verify the fixed fields using raw assembly
        address extractedArbiter;
        address extractedSponsor;
        uint256 extractedNonce;
        uint256 extractedExpires;
        bytes32 extractedMandateHash;
        bytes memory extractedAllocatorSig = new bytes(64);
        bytes memory extractedSponsorSig = new bytes(64);
        uint256 extractedClaimId;
        uint256 extractedAllocatedAmount;
        uint256 extractedClaimant;
        uint256 extractedClaimAmount;

        assembly {
            // Skip 32 bytes (length prefix) to get to actual data
            let dataStart := add(encoded, 32)

            // Extract arbiter (bytes 0-20) - shift right 96 bits to get 20 bytes
            extractedArbiter := shr(96, mload(dataStart))

            // Extract sponsor (bytes 20-40)
            extractedSponsor := shr(96, mload(add(dataStart, 20)))

            // Extract nonce (bytes 40-72)
            extractedNonce := mload(add(dataStart, 40))

            // Extract expires (bytes 72-104)
            extractedExpires := mload(add(dataStart, 72))

            // Byte 104: flags (skipped in extraction)
            // Extract mandateHash (bytes 105-136)
            extractedMandateHash := mload(add(dataStart, 105))

            // Extract allocatorSignature (bytes 137-200, 64 bytes)
            let allocatorSigPtr := add(extractedAllocatorSig, 32) // Skip length prefix
            mstore(allocatorSigPtr, mload(add(dataStart, 137)))
            mstore(add(allocatorSigPtr, 32), mload(add(dataStart, 169)))

            // Extract sponsorSignature (bytes 201-264, 64 bytes)
            let sponsorSigPtr := add(extractedSponsorSig, 32) // Skip length prefix
            mstore(sponsorSigPtr, mload(add(dataStart, 201)))
            mstore(add(sponsorSigPtr, 32), mload(add(dataStart, 233)))

            // Extract claim ID (bytes 265-296)
            extractedClaimId := mload(add(dataStart, 265))

            // Extract allocated amount (bytes 297-328)
            extractedAllocatedAmount := mload(add(dataStart, 297))

            // Extract claimant (bytes 329-360)
            extractedClaimant := mload(add(dataStart, 329))

            // Extract claim amount (bytes 361-392)
            extractedClaimAmount := mload(add(dataStart, 361))
        }

        // Verify flags byte is 0x03 (both signatures)
        uint8 flags;
        assembly {
            flags := byte(0, mload(add(encoded, add(32, 104))))
        }
        assertEq(flags, 0x03, "Flags should be 0x03 (both signatures)");

        // Verify all extracted fields
        assertEq(extractedArbiter, ARBITER, "Arbiter should match at bytes 0-20");
        assertEq(extractedSponsor, SPONSOR, "Sponsor should match at bytes 20-40");
        assertEq(extractedNonce, NONCE, "Nonce should match at bytes 40-72");
        assertEq(extractedExpires, EXPIRES, "Expires should match at bytes 72-104");
        assertEq(extractedMandateHash, MANDATE_HASH, "Mandate hash should match at bytes 104-136");
        assertEq(extractedAllocatorSig, ALLOCATOR_SIG, "Allocator signature should match at bytes 136-200");
        assertEq(extractedSponsorSig, SPONSOR_SIG, "Sponsor signature should match at bytes 200-264");

        uint256 expectedClaimId = uint256(bytes32(LOCK_TAG_1)) | uint256(uint160(TOKEN_1));
        assertEq(extractedClaimId, expectedClaimId, "Claim ID should match at bytes 264-296");
        assertEq(extractedAllocatedAmount, 1000, "Allocated amount should match at bytes 296-328");
        assertEq(extractedClaimant, uint256(CLAIMANT), "Claimant should match at bytes 328-360");
        assertEq(extractedClaimAmount, 500, "Claim amount should match at bytes 360-392");
    }

    /// @notice Test encode with multiple commitments - verify all fields with bytecode splicing
    function test_encode_multipleCommitments() public view {
        Lock[] memory commitments = new Lock[](3);
        commitments[0] = Lock({lockTag: LOCK_TAG_1, token: TOKEN_1, amount: 1000});
        commitments[1] = Lock({lockTag: LOCK_TAG_2, token: TOKEN_2, amount: 2000});
        commitments[2] = Lock({lockTag: bytes12(uint96(3)), token: address(0x6), amount: 3000});

        BatchCompact memory compact = BatchCompact({
            arbiter: ARBITER, sponsor: SPONSOR, nonce: NONCE, expires: EXPIRES, commitments: commitments
        });

        uint256[] memory claimAmounts = new uint256[](3);
        claimAmounts[0] = 500;
        claimAmounts[1] = 1500;
        claimAmounts[2] = 2500;

        bytes memory encoded = wrapper.encode(compact, SPONSOR_SIG, ALLOCATOR_SIG, MANDATE_HASH, CLAIMANT, claimAmounts);

        // Expected length: 137 (fixed + flags + mandateHash) + 128 (both sigs) + 128 * 3 (three claims) = 649 bytes
        assertEq(encoded.length, 649, "Encoded message length should be 649 bytes");

        // Splice the bytecode and verify the fixed fields using raw assembly
        address extractedArbiter;
        address extractedSponsor;
        uint256 extractedNonce;
        uint256 extractedExpires;
        bytes32 extractedMandateHash;
        bytes memory extractedAllocatorSig = new bytes(64);
        bytes memory extractedSponsorSig = new bytes(64);

        // Arrays to hold extracted claim data
        uint256[3] memory extractedClaimIds;
        uint256[3] memory extractedAllocatedAmounts;
        uint256[3] memory extractedClaimants;
        uint256[3] memory extractedClaimAmounts;

        assembly {
            let dataStart := add(encoded, 32)

            // Extract fixed fields
            extractedArbiter := shr(96, mload(dataStart))
            extractedSponsor := shr(96, mload(add(dataStart, 20)))
            extractedNonce := mload(add(dataStart, 40))
            extractedExpires := mload(add(dataStart, 72))
            // Byte 104: flags (skipped)
            extractedMandateHash := mload(add(dataStart, 105))

            let allocatorSigPtr := add(extractedAllocatorSig, 32)
            mstore(allocatorSigPtr, mload(add(dataStart, 137)))
            mstore(add(allocatorSigPtr, 32), mload(add(dataStart, 169)))

            let sponsorSigPtr := add(extractedSponsorSig, 32)
            mstore(sponsorSigPtr, mload(add(dataStart, 201)))
            mstore(add(sponsorSigPtr, 32), mload(add(dataStart, 233)))

            // Extract claim 0 (bytes 265-392)
            mstore(extractedClaimIds, mload(add(dataStart, 265)))
            mstore(extractedAllocatedAmounts, mload(add(dataStart, 297)))
            mstore(extractedClaimants, mload(add(dataStart, 329)))
            mstore(extractedClaimAmounts, mload(add(dataStart, 361)))

            // Extract claim 1 (bytes 393-520)
            mstore(add(extractedClaimIds, 32), mload(add(dataStart, 393)))
            mstore(add(extractedAllocatedAmounts, 32), mload(add(dataStart, 425)))
            mstore(add(extractedClaimants, 32), mload(add(dataStart, 457)))
            mstore(add(extractedClaimAmounts, 32), mload(add(dataStart, 489)))

            // Extract claim 2 (bytes 521-648)
            mstore(add(extractedClaimIds, 64), mload(add(dataStart, 521)))
            mstore(add(extractedAllocatedAmounts, 64), mload(add(dataStart, 553)))
            mstore(add(extractedClaimants, 64), mload(add(dataStart, 585)))
            mstore(add(extractedClaimAmounts, 64), mload(add(dataStart, 617)))
        }

        // Verify flags byte is 0x03 (both signatures)
        uint8 flags;
        assembly {
            flags := byte(0, mload(add(encoded, add(32, 104))))
        }
        assertEq(flags, 0x03, "Flags should be 0x03 (both signatures)");

        // Verify fixed fields
        assertEq(extractedArbiter, ARBITER, "Arbiter should match at bytes 0-20");
        assertEq(extractedSponsor, SPONSOR, "Sponsor should match at bytes 20-40");
        assertEq(extractedNonce, NONCE, "Nonce should match at bytes 40-72");
        assertEq(extractedExpires, EXPIRES, "Expires should match at bytes 72-104");
        assertEq(extractedMandateHash, MANDATE_HASH, "Mandate hash should match at bytes 104-136");
        assertEq(extractedAllocatorSig, ALLOCATOR_SIG, "Allocator signature should match at bytes 136-200");
        assertEq(extractedSponsorSig, SPONSOR_SIG, "Sponsor signature should match at bytes 200-264");

        // Verify claim 0 (bytes 264-392)
        uint256 expectedClaimId0 = uint256(bytes32(LOCK_TAG_1)) | uint256(uint160(TOKEN_1));
        assertEq(extractedClaimIds[0], expectedClaimId0, "Claim 0 ID should match at bytes 264-296");
        assertEq(extractedAllocatedAmounts[0], 1000, "Claim 0 allocated amount should match at bytes 296-328");
        assertEq(extractedClaimants[0], uint256(CLAIMANT), "Claim 0 claimant should match at bytes 328-360");
        assertEq(extractedClaimAmounts[0], 500, "Claim 0 amount should match at bytes 360-392");

        // Verify claim 1 (bytes 392-520)
        uint256 expectedClaimId1 = uint256(bytes32(LOCK_TAG_2)) | uint256(uint160(TOKEN_2));
        assertEq(extractedClaimIds[1], expectedClaimId1, "Claim 1 ID should match at bytes 392-424");
        assertEq(extractedAllocatedAmounts[1], 2000, "Claim 1 allocated amount should match at bytes 424-456");
        assertEq(extractedClaimants[1], uint256(CLAIMANT), "Claim 1 claimant should match at bytes 456-488");
        assertEq(extractedClaimAmounts[1], 1500, "Claim 1 amount should match at bytes 488-520");

        // Verify claim 2 (bytes 520-648)
        uint256 expectedClaimId2 = uint256(bytes32(bytes12(uint96(3)))) | uint256(uint160(address(0x6)));
        assertEq(extractedClaimIds[2], expectedClaimId2, "Claim 2 ID should match at bytes 520-552");
        assertEq(extractedAllocatedAmounts[2], 3000, "Claim 2 allocated amount should match at bytes 552-584");
        assertEq(extractedClaimants[2], uint256(CLAIMANT), "Claim 2 claimant should match at bytes 584-616");
        assertEq(extractedClaimAmounts[2], 2500, "Claim 2 amount should match at bytes 616-648");
    }

    /// @notice Test that encode reverts with invalid sponsor signature length
    function test_encode_revertsOnInvalidSponsorSigLength() public {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: LOCK_TAG_1, token: TOKEN_1, amount: 1000});

        BatchCompact memory compact = BatchCompact({
            arbiter: ARBITER, sponsor: SPONSOR, nonce: NONCE, expires: EXPIRES, commitments: commitments
        });

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = 500;

        bytes memory invalidSig = hex"1111"; // Only 2 bytes instead of 64

        vm.expectRevert("invalid message signature length");
        wrapper.encode(compact, invalidSig, ALLOCATOR_SIG, MANDATE_HASH, CLAIMANT, claimAmounts);
    }

    /// @notice Test that encode reverts with invalid allocator signature length
    function test_encode_revertsOnInvalidAllocatorSigLength() public {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: LOCK_TAG_1, token: TOKEN_1, amount: 1000});

        BatchCompact memory compact = BatchCompact({
            arbiter: ARBITER, sponsor: SPONSOR, nonce: NONCE, expires: EXPIRES, commitments: commitments
        });

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = 500;

        bytes memory invalidSig = hex"3333"; // Only 2 bytes instead of 64

        vm.expectRevert("invalid message signature length");
        wrapper.encode(compact, SPONSOR_SIG, invalidSig, MANDATE_HASH, CLAIMANT, claimAmounts);
    }

    /// @notice Test decode with valid single claim message
    function test_decode_singleClaim() public {
        // Create a properly formatted message
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: LOCK_TAG_1, token: TOKEN_1, amount: 1000});

        BatchCompact memory compact = BatchCompact({
            arbiter: address(wrapper), // Use wrapper contract as arbiter
            sponsor: SPONSOR,
            nonce: NONCE,
            expires: EXPIRES,
            commitments: commitments
        });

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = 500;

        bytes memory encoded = wrapper.encode(compact, SPONSOR_SIG, ALLOCATOR_SIG, MANDATE_HASH, CLAIMANT, claimAmounts);

        (
            address decodedSponsor,
            uint256 decodedNonce,
            uint256 decodedExpires,
            bytes memory decodedAllocatorSig,
            bytes memory decodedSponsorSig,
            bytes32 decodedWitness,
            BatchClaimComponent[] memory decodedClaims
        ) = wrapper.decode(encoded);

        // Verify decoded values
        assertEq(decodedSponsor, SPONSOR, "Sponsor should match");
        assertEq(decodedNonce, NONCE, "Nonce should match");
        assertEq(decodedExpires, EXPIRES, "Expires should match");
        assertEq(decodedAllocatorSig, ALLOCATOR_SIG, "Allocator signature should match");
        assertEq(decodedSponsorSig, SPONSOR_SIG, "Sponsor signature should match");
        assertEq(decodedWitness, MANDATE_HASH, "Witness should match");
        assertEq(decodedClaims.length, 1, "Should have 1 claim");

        // Verify claim details
        uint256 expectedId = uint256(bytes32(LOCK_TAG_1)) | uint256(uint160(TOKEN_1));
        assertEq(decodedClaims[0].id, expectedId, "Claim ID should match");
        assertEq(decodedClaims[0].allocatedAmount, 1000, "Allocated amount should match");
        assertEq(decodedClaims[0].portions.length, 1, "Should have 1 portion");
        assertEq(decodedClaims[0].portions[0].claimant, uint256(CLAIMANT), "Claimant should match");
        assertEq(decodedClaims[0].portions[0].amount, 500, "Claim amount should match");
    }

    /// @notice Test decode with multiple claims - verifies decode function works correctly
    function test_decode_multipleClaims() public {
        Lock[] memory commitments = new Lock[](3);
        commitments[0] = Lock({lockTag: LOCK_TAG_1, token: TOKEN_1, amount: 1000});
        commitments[1] = Lock({lockTag: LOCK_TAG_2, token: TOKEN_2, amount: 2000});
        commitments[2] = Lock({lockTag: bytes12(uint96(3)), token: address(0x6), amount: 3000});

        BatchCompact memory compact = BatchCompact({
            arbiter: address(wrapper), sponsor: SPONSOR, nonce: NONCE, expires: EXPIRES, commitments: commitments
        });

        uint256[] memory claimAmounts = new uint256[](3);
        claimAmounts[0] = 500;
        claimAmounts[1] = 1500;
        claimAmounts[2] = 2500;

        bytes memory encoded = wrapper.encode(compact, SPONSOR_SIG, ALLOCATOR_SIG, MANDATE_HASH, CLAIMANT, claimAmounts);

        // Decode and verify
        (
            address decodedSponsor,
            uint256 decodedNonce,
            uint256 decodedExpires,
            bytes memory decodedAllocatorSig,
            bytes memory decodedSponsorSig,
            bytes32 decodedWitness,
            BatchClaimComponent[] memory decodedClaims
        ) = wrapper.decode(encoded);

        // Verify fixed fields
        assertEq(decodedSponsor, SPONSOR, "Sponsor should match");
        assertEq(decodedNonce, NONCE, "Nonce should match");
        assertEq(decodedExpires, EXPIRES, "Expires should match");
        assertEq(decodedAllocatorSig, ALLOCATOR_SIG, "Allocator signature should match");
        assertEq(decodedSponsorSig, SPONSOR_SIG, "Sponsor signature should match");
        assertEq(decodedWitness, MANDATE_HASH, "Witness should match");
        assertEq(decodedClaims.length, 3, "Should have 3 claims");

        // Verify claim 0
        uint256 expectedId0 = uint256(bytes32(LOCK_TAG_1)) | uint256(uint160(TOKEN_1));
        assertEq(decodedClaims[0].id, expectedId0, "Claim 0 ID should match");
        assertEq(decodedClaims[0].allocatedAmount, 1000, "Claim 0 allocated amount should match");
        assertEq(decodedClaims[0].portions.length, 1, "Claim 0 should have 1 portion");
        assertEq(decodedClaims[0].portions[0].claimant, uint256(CLAIMANT), "Claim 0 claimant should match");
        assertEq(decodedClaims[0].portions[0].amount, 500, "Claim 0 amount should match");

        // Verify claim 1
        uint256 expectedId1 = uint256(bytes32(LOCK_TAG_2)) | uint256(uint160(TOKEN_2));
        assertEq(decodedClaims[1].id, expectedId1, "Claim 1 ID should match");
        assertEq(decodedClaims[1].allocatedAmount, 2000, "Claim 1 allocated amount should match");
        assertEq(decodedClaims[1].portions.length, 1, "Claim 1 should have 1 portion");
        assertEq(decodedClaims[1].portions[0].claimant, uint256(CLAIMANT), "Claim 1 claimant should match");
        assertEq(decodedClaims[1].portions[0].amount, 1500, "Claim 1 amount should match");

        // Verify claim 2
        uint256 expectedId2 = uint256(bytes32(bytes12(uint96(3)))) | uint256(uint160(address(0x6)));
        assertEq(decodedClaims[2].id, expectedId2, "Claim 2 ID should match");
        assertEq(decodedClaims[2].allocatedAmount, 3000, "Claim 2 allocated amount should match");
        assertEq(decodedClaims[2].portions.length, 1, "Claim 2 should have 1 portion");
        assertEq(decodedClaims[2].portions[0].claimant, uint256(CLAIMANT), "Claim 2 claimant should match");
        assertEq(decodedClaims[2].portions[0].amount, 2500, "Claim 2 amount should match");
    }

    /// @notice Test decode reverts on invalid message length
    function test_decode_revertsOnInvalidLength() public {
        bytes memory invalidMessage = hex"1234"; // Too short

        // Expect arithmetic underflow/overflow panic (0x11) because the length check causes subtraction underflow
        vm.expectRevert();
        wrapper.decode(invalidMessage);
    }

    /// @notice Test decode reverts on wrong arbiter
    function test_decode_revertsOnWrongArbiter() public {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: LOCK_TAG_1, token: TOKEN_1, amount: 1000});

        BatchCompact memory compact = BatchCompact({
            arbiter: address(0x9999), // Wrong arbiter
            sponsor: SPONSOR,
            nonce: NONCE,
            expires: EXPIRES,
            commitments: commitments
        });

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = 500;

        bytes memory encoded = wrapper.encode(compact, SPONSOR_SIG, ALLOCATOR_SIG, MANDATE_HASH, CLAIMANT, claimAmounts);

        vm.expectRevert("invalid arbiter");
        wrapper.decode(encoded);
    }

    /// @notice Fuzz test: encode/decode round trip preserves data
    function testFuzz_encodeDecodeRoundTrip(
        address sponsor,
        uint256 nonce,
        uint256 expires,
        uint256 amount,
        uint256 claimAmount
    ) public {
        vm.assume(sponsor != address(0));
        vm.assume(claimAmount <= amount);

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: LOCK_TAG_1, token: TOKEN_1, amount: amount});

        BatchCompact memory compact = BatchCompact({
            arbiter: address(wrapper), // Use wrapper contract as arbiter
            sponsor: sponsor,
            nonce: nonce,
            expires: expires,
            commitments: commitments
        });

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = claimAmount;

        bytes memory encoded = wrapper.encode(compact, SPONSOR_SIG, ALLOCATOR_SIG, MANDATE_HASH, CLAIMANT, claimAmounts);

        (
            address decodedSponsor,
            uint256 decodedNonce,
            uint256 decodedExpires,,,,
            BatchClaimComponent[] memory decodedClaims
        ) = wrapper.decode(encoded);

        assertEq(decodedSponsor, sponsor, "Sponsor should be preserved");
        assertEq(decodedNonce, nonce, "Nonce should be preserved");
        assertEq(decodedExpires, expires, "Expires should be preserved");
        assertEq(decodedClaims[0].allocatedAmount, amount, "Amount should be preserved");
        assertEq(decodedClaims[0].portions[0].amount, claimAmount, "Claim amount should be preserved");
    }

    /// @notice Test gas consumption for encode with varying number of commitments
    function test_gas_encodeScaling() public {
        for (uint256 numCommitments = 1; numCommitments <= 10; numCommitments++) {
            Lock[] memory commitments = new Lock[](numCommitments);
            uint256[] memory claimAmounts = new uint256[](numCommitments);

            for (uint256 i = 0; i < numCommitments; i++) {
                commitments[i] = Lock({lockTag: bytes12(uint96(i + 1)), token: TOKEN_1, amount: 1000 * (i + 1)});
                claimAmounts[i] = 500 * (i + 1);
            }

            BatchCompact memory compact = BatchCompact({
                arbiter: ARBITER, sponsor: SPONSOR, nonce: NONCE, expires: EXPIRES, commitments: commitments
            });

            uint256 gasBefore = gasleft();
            wrapper.encode(compact, SPONSOR_SIG, ALLOCATOR_SIG, MANDATE_HASH, CLAIMANT, claimAmounts);
            uint256 gasUsed = gasBefore - gasleft();

            // Log for analysis (visible with -vvv flag)
            emit log_named_uint("Gas used for encoding with commitments:", numCommitments);
            emit log_named_uint("Gas amount:", gasUsed);
        }
    }

    /// @notice Test gas consumption for decode with varying number of commitments
    function test_gas_decodeScaling() public {
        for (uint256 numCommitments = 1; numCommitments <= 10; numCommitments++) {
            Lock[] memory commitments = new Lock[](numCommitments);
            uint256[] memory claimAmounts = new uint256[](numCommitments);

            for (uint256 i = 0; i < numCommitments; i++) {
                commitments[i] = Lock({lockTag: bytes12(uint96(i + 1)), token: TOKEN_1, amount: 1000 * (i + 1)});
                claimAmounts[i] = 500 * (i + 1);
            }

            BatchCompact memory compact = BatchCompact({
                arbiter: address(wrapper), // Use wrapper as arbiter for decode to work
                sponsor: SPONSOR,
                nonce: NONCE,
                expires: EXPIRES,
                commitments: commitments
            });

            // First encode the message
            bytes memory encoded =
                wrapper.encode(compact, SPONSOR_SIG, ALLOCATOR_SIG, MANDATE_HASH, CLAIMANT, claimAmounts);

            // Measure decode gas
            uint256 gasBefore = gasleft();
            wrapper.decode(encoded);
            uint256 gasUsed = gasBefore - gasleft();

            // Log for analysis (visible with -vvv flag)
            emit log_named_uint("Gas used for decoding with commitments:", numCommitments);
            emit log_named_uint("Gas amount:", gasUsed);
        }
    }

    /// @notice Test encode with both signatures empty (0 bytes)
    function test_encode_bothSignaturesEmpty() public view {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: LOCK_TAG_1, token: TOKEN_1, amount: 1000});

        BatchCompact memory compact = BatchCompact({
            arbiter: ARBITER, sponsor: SPONSOR, nonce: NONCE, expires: EXPIRES, commitments: commitments
        });

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = 500;

        bytes memory emptySig = "";
        bytes memory encoded = wrapper.encode(compact, emptySig, emptySig, MANDATE_HASH, CLAIMANT, claimAmounts);

        // Expected length: 137 (fixed header + flags + mandateHash) + 0 (no sigs) + 128 (one claim) = 265 bytes
        assertEq(encoded.length, 265, "Encoded message length should be 265 bytes");

        // Verify flags byte is 0x00 (no signatures)
        uint8 flags;
        assembly {
            flags := byte(0, mload(add(encoded, add(32, 104))))
        }
        assertEq(flags, 0x00, "Flags should be 0x00 (no signatures)");
    }

    /// @notice Test encode with only allocator signature
    function test_encode_onlyAllocatorSignature() public view {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: LOCK_TAG_1, token: TOKEN_1, amount: 1000});

        BatchCompact memory compact = BatchCompact({
            arbiter: ARBITER, sponsor: SPONSOR, nonce: NONCE, expires: EXPIRES, commitments: commitments
        });

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = 500;

        bytes memory emptySig = "";
        bytes memory encoded = wrapper.encode(compact, emptySig, ALLOCATOR_SIG, MANDATE_HASH, CLAIMANT, claimAmounts);

        // Expected length: 137 + 64 (allocator sig only) + 128 = 329 bytes
        assertEq(encoded.length, 329, "Encoded message length should be 329 bytes");

        // Verify flags byte is 0x01 (only allocator signature)
        uint8 flags;
        assembly {
            flags := byte(0, mload(add(encoded, add(32, 104))))
        }
        assertEq(flags, 0x01, "Flags should be 0x01 (only allocator signature)");
    }

    /// @notice Test encode with only sponsor signature
    function test_encode_onlySponsorSignature() public view {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: LOCK_TAG_1, token: TOKEN_1, amount: 1000});

        BatchCompact memory compact = BatchCompact({
            arbiter: ARBITER, sponsor: SPONSOR, nonce: NONCE, expires: EXPIRES, commitments: commitments
        });

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = 500;

        bytes memory emptySig = "";
        bytes memory encoded = wrapper.encode(compact, SPONSOR_SIG, emptySig, MANDATE_HASH, CLAIMANT, claimAmounts);

        // Expected length: 137 + 64 (sponsor sig only) + 128 = 329 bytes
        assertEq(encoded.length, 329, "Encoded message length should be 329 bytes");

        // Verify flags byte is 0x02 (only sponsor signature)
        uint8 flags;
        assembly {
            flags := byte(0, mload(add(encoded, add(32, 104))))
        }
        assertEq(flags, 0x02, "Flags should be 0x02 (only sponsor signature)");
    }

    /// @notice Test decode with both signatures empty
    function test_decode_bothSignaturesEmpty() public {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: LOCK_TAG_1, token: TOKEN_1, amount: 1000});

        BatchCompact memory compact = BatchCompact({
            arbiter: address(wrapper), sponsor: SPONSOR, nonce: NONCE, expires: EXPIRES, commitments: commitments
        });

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = 500;

        bytes memory emptySig = "";
        bytes memory encoded = wrapper.encode(compact, emptySig, emptySig, MANDATE_HASH, CLAIMANT, claimAmounts);

        (
            address decodedSponsor,
            uint256 decodedNonce,
            uint256 decodedExpires,
            bytes memory decodedAllocatorSig,
            bytes memory decodedSponsorSig,
            bytes32 decodedWitness,
            BatchClaimComponent[] memory decodedClaims
        ) = wrapper.decode(encoded);

        assertEq(decodedSponsor, SPONSOR, "Sponsor should match");
        assertEq(decodedNonce, NONCE, "Nonce should match");
        assertEq(decodedExpires, EXPIRES, "Expires should match");
        assertEq(decodedAllocatorSig.length, 0, "Allocator signature should be empty");
        assertEq(decodedSponsorSig.length, 0, "Sponsor signature should be empty");
        assertEq(decodedWitness, MANDATE_HASH, "Witness should match");
        assertEq(decodedClaims.length, 1, "Should have 1 claim");
    }

    /// @notice Test decode with only allocator signature
    function test_decode_onlyAllocatorSignature() public {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: LOCK_TAG_1, token: TOKEN_1, amount: 1000});

        BatchCompact memory compact = BatchCompact({
            arbiter: address(wrapper), sponsor: SPONSOR, nonce: NONCE, expires: EXPIRES, commitments: commitments
        });

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = 500;

        bytes memory emptySig = "";
        bytes memory encoded = wrapper.encode(compact, emptySig, ALLOCATOR_SIG, MANDATE_HASH, CLAIMANT, claimAmounts);

        (,,, bytes memory decodedAllocatorSig, bytes memory decodedSponsorSig,,) = wrapper.decode(encoded);

        assertEq(decodedAllocatorSig, ALLOCATOR_SIG, "Allocator signature should match");
        assertEq(decodedSponsorSig.length, 0, "Sponsor signature should be empty");
    }

    /// @notice Test decode with only sponsor signature
    function test_decode_onlySponsorSignature() public {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: LOCK_TAG_1, token: TOKEN_1, amount: 1000});

        BatchCompact memory compact = BatchCompact({
            arbiter: address(wrapper), sponsor: SPONSOR, nonce: NONCE, expires: EXPIRES, commitments: commitments
        });

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = 500;

        bytes memory emptySig = "";
        bytes memory encoded = wrapper.encode(compact, SPONSOR_SIG, emptySig, MANDATE_HASH, CLAIMANT, claimAmounts);

        (,,, bytes memory decodedAllocatorSig, bytes memory decodedSponsorSig,,) = wrapper.decode(encoded);

        assertEq(decodedAllocatorSig.length, 0, "Allocator signature should be empty");
        assertEq(decodedSponsorSig, SPONSOR_SIG, "Sponsor signature should match");
    }

    /// @notice Test encode/decode round trip with empty signatures
    function test_roundTrip_emptySignatures() public {
        Lock[] memory commitments = new Lock[](2);
        commitments[0] = Lock({lockTag: LOCK_TAG_1, token: TOKEN_1, amount: 1000});
        commitments[1] = Lock({lockTag: LOCK_TAG_2, token: TOKEN_2, amount: 2000});

        BatchCompact memory compact = BatchCompact({
            arbiter: address(wrapper), sponsor: SPONSOR, nonce: NONCE, expires: EXPIRES, commitments: commitments
        });

        uint256[] memory claimAmounts = new uint256[](2);
        claimAmounts[0] = 500;
        claimAmounts[1] = 1500;

        bytes memory emptySig = "";
        bytes memory encoded = wrapper.encode(compact, emptySig, emptySig, MANDATE_HASH, CLAIMANT, claimAmounts);

        (
            address decodedSponsor,
            uint256 decodedNonce,
            uint256 decodedExpires,
            bytes memory decodedAllocatorSig,
            bytes memory decodedSponsorSig,
            bytes32 decodedWitness,
            BatchClaimComponent[] memory decodedClaims
        ) = wrapper.decode(encoded);

        // Verify all fields preserved
        assertEq(decodedSponsor, SPONSOR, "Sponsor should be preserved");
        assertEq(decodedNonce, NONCE, "Nonce should be preserved");
        assertEq(decodedExpires, EXPIRES, "Expires should be preserved");
        assertEq(decodedAllocatorSig.length, 0, "Allocator signature should be empty");
        assertEq(decodedSponsorSig.length, 0, "Sponsor signature should be empty");
        assertEq(decodedWitness, MANDATE_HASH, "Witness should be preserved");
        assertEq(decodedClaims.length, 2, "Should have 2 claims");

        // Verify claims preserved
        uint256 expectedId0 = uint256(bytes32(LOCK_TAG_1)) | uint256(uint160(TOKEN_1));
        assertEq(decodedClaims[0].id, expectedId0, "Claim 0 ID should match");
        assertEq(decodedClaims[0].allocatedAmount, 1000, "Claim 0 allocated amount should match");
    }

    /// @notice Test that message size is correctly reduced with empty signatures
    function test_messageSizeReduction() public view {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: LOCK_TAG_1, token: TOKEN_1, amount: 1000});

        BatchCompact memory compact = BatchCompact({
            arbiter: ARBITER, sponsor: SPONSOR, nonce: NONCE, expires: EXPIRES, commitments: commitments
        });

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = 500;

        bytes memory emptySig = "";

        // Both signatures present
        bytes memory fullMsg = wrapper.encode(compact, SPONSOR_SIG, ALLOCATOR_SIG, MANDATE_HASH, CLAIMANT, claimAmounts);

        // Only allocator signature
        bytes memory oneMsg = wrapper.encode(compact, emptySig, ALLOCATOR_SIG, MANDATE_HASH, CLAIMANT, claimAmounts);

        // No signatures
        bytes memory emptyMsg = wrapper.encode(compact, emptySig, emptySig, MANDATE_HASH, CLAIMANT, claimAmounts);

        // Verify size differences
        assertEq(fullMsg.length, oneMsg.length + 64, "Should save 64 bytes with one empty signature");
        assertEq(fullMsg.length, emptyMsg.length + 128, "Should save 128 bytes with both empty signatures");
    }
}
