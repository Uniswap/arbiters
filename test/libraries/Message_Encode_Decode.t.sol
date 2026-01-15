// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Message} from "../../src/libraries/Message.sol";
import {Lock} from "the-compact/src/types/EIP712Types.sol";
import {BatchClaim} from "the-compact/src/types/BatchClaims.sol";

//TODO add encoding and decoding tests independently of each other
// with assembly level verification of the encoded and decoded data

/// @title MessageWrapper
/// @notice Wrapper contract to call Message library functions in tests
/// @dev Needed because library functions use calldata parameters
contract MessageWrapper {
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
    ) external pure returns (bytes memory) {
        return Message.encode(
            sponsor,
            nonce,
            expires,
            witness,
            commitments,
            allocatorData,
            sponsorSignature,
            claimant,
            claimReductionScalingFactor
        );
    }

    function decode(bytes calldata message) external pure returns (BatchClaim memory) {
        return Message.decode(message);
    }
}

/// @title MessageTest
/// @notice Comprehensive test suite for the Message library
/// @dev Tests encoding, decoding, and all helper functions
contract MessageTest is Test {
    MessageWrapper public wrapper;

    // BatchCompact metadata
    address constant SPONSOR = 0x1111111111111111111111111111111111111111;
    uint256 constant NONCE = 0x2222222222222222222222222222222222222222222222222222222222222222;
    uint256 constant EXPIRES = 0x3333333333333333333333333333333333333333333333333333333333333333;
    bytes32 constant WITNESS = keccak256("witness");
    uint256 constant CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT = 1e18;
    uint256 constant CLAIM_REDUCTION_SCALING_FACTOR_REDUCED = 0.5e18;
    bytes32 constant CLAIMANT = 0x9999999999999999999999999999999999999999999999999999999999999999;

    // Mock Signatures (64 bytes each)
    bytes constant SPONSOR_SIG = hex"1111111111111111111111111111111111111111111111111111111111111111"
        hex"2222222222222222222222222222222222222222222222222222222222222222";
    bytes constant ALLOCATOR_SIG = hex"3333333333333333333333333333333333333333333333333333333333333333"
        hex"4444444444444444444444444444444444444444444444444444444444444444";

    function createSingleLock() internal pure returns (Lock[] memory) {
        Lock[] memory locks = new Lock[](1);
        locks[0] = Lock({
            lockTag: bytes12(uint96(0x123456789ABC)),
            token: address(0x1111111111111111111111111111111111111111),
            amount: 1000e18
        });
        return locks;
    }

    function createMultipleLocks() internal pure returns (Lock[] memory) {
        Lock[] memory locks = new Lock[](3);
        locks[0] = Lock({
            lockTag: bytes12(uint96(0x123456789ABC)),
            token: address(0x1111111111111111111111111111111111111111),
            amount: 1000e18
        });
        locks[1] = Lock({
            lockTag: bytes12(uint96(0xDEF012345678)),
            token: address(0x2222222222222222222222222222222222222222),
            amount: 2000e18
        });
        locks[2] = Lock({
            lockTag: bytes12(uint96(0x9ABCDEF01234)),
            token: address(0x3333333333333333333333333333333333333333),
            amount: 3000e18
        });
        return locks;
    }

    function assertLocksEqual(Lock[] memory expected, Lock[] memory actual) internal pure {
        require(expected.length == actual.length, "Lock array length mismatch");
        for (uint256 i = 0; i < expected.length; i++) {
            require(expected[i].lockTag == actual[i].lockTag, "lockTag mismatch");
            require(expected[i].token == actual[i].token, "token mismatch");
            require(expected[i].amount == actual[i].amount, "amount mismatch");
        }
    }

    function assertBatchClaimEqual(
        address expectedSponsor,
        uint256 expectedNonce,
        uint256 expectedExpires,
        bytes32 expectedWitness,
        bytes32 expectedClaimant,
        bytes memory expectedAllocatorData,
        bytes memory expectedSponsorSig,
        Lock[] memory expectedLocks,
        uint256 claimReductionScalingFactor,
        BatchClaim memory actual
    ) internal pure {
        require(actual.sponsor == expectedSponsor, "sponsor mismatch");
        require(actual.nonce == expectedNonce, "nonce mismatch");
        require(actual.expires == expectedExpires, "expires mismatch");
        require(actual.witness == expectedWitness, "witness mismatch");
        require(keccak256(actual.allocatorData) == keccak256(expectedAllocatorData), "allocatorData mismatch");
        require(keccak256(actual.sponsorSignature) == keccak256(expectedSponsorSig), "sponsorSignature mismatch");

        require(actual.claims.length == expectedLocks.length, "claims length mismatch");

        for (uint256 i = 0; i < expectedLocks.length; i++) {
            uint256 expectedId = uint256(bytes32(expectedLocks[i].lockTag)) | uint256(uint160(expectedLocks[i].token));
            require(actual.claims[i].id == expectedId, "claim id mismatch - must match lockTag+token");

            require(actual.claims[i].allocatedAmount == expectedLocks[i].amount, "allocatedAmount mismatch");

            // Handle zero scaling factor case (cancelled claims)
            if (claimReductionScalingFactor == 0) {
                require(actual.claims[i].portions.length == 0, "portions should be empty for zero scaling factor");
            } else {
                // Verify portions array has single element
                require(actual.claims[i].portions.length == 1, "portions length should be 1");

                require(
                    keccak256(abi.encodePacked(actual.claims[i].portions[0].claimant))
                        == keccak256(abi.encodePacked(expectedClaimant)),
                    "claimant mismatch"
                );

                uint256 expectedScaledAmount;
                if (claimReductionScalingFactor == 1e18) {
                    expectedScaledAmount = expectedLocks[i].amount;
                } else {
                    expectedScaledAmount = (expectedLocks[i].amount * claimReductionScalingFactor) / 1e18;
                }
                require(actual.claims[i].portions[0].amount == expectedScaledAmount, "scaled amount mismatch");
            }
        }
    }

    function setUp() public {
        wrapper = new MessageWrapper();
    }

    //////////////////////////////////////////////////////////////
    // VALIDATION TESTS
    //////////////////////////////////////////////////////////////

    /// @notice Test that encode reverts when allocator data exceeds uint16 max length
    function test_encode_revertsOnAllocatorDataTooLong() public {
        Lock[] memory locks = createSingleLock();

        // Create allocator data that exceeds uint16.max (65535 bytes)
        // We can't actually create a 65536+ byte array in a single test due to memory limits,
        // but we can use vm.expectRevert with a crafted calldata
        vm.expectRevert("allocator data too long");

        // This will fail in practice due to memory, but the revert check is what matters
        bytes memory tooLong = new bytes(65536);
        wrapper.encode(
            SPONSOR, NONCE, EXPIRES, WITNESS, locks, tooLong, hex"", CLAIMANT, CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT
        );
    }

    /// @notice Test that encode reverts when sponsor signature exceeds uint16 max length
    function test_encode_revertsOnSponsorSignatureTooLong() public {
        Lock[] memory locks = createSingleLock();

        vm.expectRevert("sponsor signature too long");

        bytes memory tooLong = new bytes(65536);
        wrapper.encode(
            SPONSOR, NONCE, EXPIRES, WITNESS, locks, hex"", tooLong, CLAIMANT, CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT
        );
    }

    /// @notice Test that encode succeeds with signatures at exactly uint16 max length
    function test_encode_succeedsAtMaxLength() public view {
        Lock[] memory locks = createSingleLock();

        // Create signatures at exactly uint16.max (65535 bytes)
        bytes memory maxLengthSig = new bytes(65535);

        // Should not revert - exactly at the limit
        bytes memory encoded = wrapper.encode(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            maxLengthSig,
            maxLengthSig,
            CLAIMANT,
            CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT
        );

        // Verify it decodes correctly
        BatchClaim memory decoded = wrapper.decode(encoded);
        assertBatchClaimEqual(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            CLAIMANT,
            maxLengthSig,
            maxLengthSig,
            locks,
            CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT,
            decoded
        );
    }

    //////////////////////////////////////////////////////////////
    // ROUND TRIP TESTS
    //////////////////////////////////////////////////////////////

    /// @notice Test round trip with single lock and both signatures
    function test_roundTrip_singleLock_bothSignatures() public view {
        Lock[] memory locks = createSingleLock();

        bytes memory encoded = wrapper.encode(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            ALLOCATOR_SIG,
            SPONSOR_SIG,
            CLAIMANT,
            CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT
        );

        BatchClaim memory decoded = wrapper.decode(encoded);

        assertBatchClaimEqual(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            CLAIMANT,
            ALLOCATOR_SIG,
            SPONSOR_SIG,
            locks,
            CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT,
            decoded
        );
    }

    /// @notice Test round trip with single lock and zero signatures
    function test_roundTrip_singleLock_zeroSignatures() public view {
        Lock[] memory locks = createSingleLock();

        bytes memory encoded = wrapper.encode(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            hex"", // no allocator signature
            hex"", // no sponsor signature
            CLAIMANT,
            CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT
        );

        BatchClaim memory decoded = wrapper.decode(encoded);

        assertBatchClaimEqual(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            CLAIMANT,
            hex"",
            hex"",
            locks,
            CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT,
            decoded
        );
    }

    /// @notice Test round trip with single lock and only allocator signature
    function test_roundTrip_singleLock_onlyAllocatorSignature() public view {
        Lock[] memory locks = createSingleLock();

        bytes memory encoded = wrapper.encode(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            ALLOCATOR_SIG,
            hex"", // no sponsor signature
            CLAIMANT,
            CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT
        );

        BatchClaim memory decoded = wrapper.decode(encoded);

        assertBatchClaimEqual(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            CLAIMANT,
            ALLOCATOR_SIG,
            hex"",
            locks,
            CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT,
            decoded
        );
    }

    /// @notice Test round trip with single lock and only sponsor signature
    function test_roundTrip_singleLock_onlySponsorSignature() public view {
        Lock[] memory locks = createSingleLock();

        bytes memory encoded = wrapper.encode(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            hex"", // no allocator signature
            SPONSOR_SIG,
            CLAIMANT,
            CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT
        );

        BatchClaim memory decoded = wrapper.decode(encoded);

        assertBatchClaimEqual(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            CLAIMANT,
            hex"",
            SPONSOR_SIG,
            locks,
            CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT,
            decoded
        );
    }

    /// @notice Test round trip with single lock and reduced scaling factor (0.5e18)
    function test_roundTrip_singleLock_reducedScalingFactor() public view {
        Lock[] memory locks = createSingleLock();

        bytes memory encoded = wrapper.encode(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            ALLOCATOR_SIG,
            SPONSOR_SIG,
            CLAIMANT,
            CLAIM_REDUCTION_SCALING_FACTOR_REDUCED // 0.5e18 = 50% reduction
        );

        BatchClaim memory decoded = wrapper.decode(encoded);

        assertBatchClaimEqual(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            CLAIMANT,
            ALLOCATOR_SIG,
            SPONSOR_SIG,
            locks,
            CLAIM_REDUCTION_SCALING_FACTOR_REDUCED,
            decoded
        );
    }

    /// @notice Test round trip with single lock and zero scaling factor (cancelled claim)
    function test_roundTrip_singleLock_zeroScalingFactor() public view {
        Lock[] memory locks = createSingleLock();

        bytes memory encoded = wrapper.encode(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            ALLOCATOR_SIG,
            SPONSOR_SIG,
            CLAIMANT,
            0 // Zero scaling factor = cancelled claim
        );

        BatchClaim memory decoded = wrapper.decode(encoded);

        assertBatchClaimEqual(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            CLAIMANT,
            ALLOCATOR_SIG,
            SPONSOR_SIG,
            locks,
            0, // Zero scaling factor
            decoded
        );
    }

    /// @notice Test round trip with multiple locks and zero scaling factor
    function test_roundTrip_multipleLocks_zeroScalingFactor() public view {
        Lock[] memory locks = createMultipleLocks();

        bytes memory encoded = wrapper.encode(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            ALLOCATOR_SIG,
            SPONSOR_SIG,
            CLAIMANT,
            0 // Zero scaling factor = cancelled claim
        );

        BatchClaim memory decoded = wrapper.decode(encoded);

        assertBatchClaimEqual(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            CLAIMANT,
            ALLOCATOR_SIG,
            SPONSOR_SIG,
            locks,
            0, // Zero scaling factor
            decoded
        );
    }

    /// @notice Test round trip with multiple locks and zero signatures
    function test_roundTrip_multipleLocks_zeroSignatures() public view {
        Lock[] memory locks = createMultipleLocks();

        bytes memory encoded = wrapper.encode(
            SPONSOR, NONCE, EXPIRES, WITNESS, locks, hex"", hex"", CLAIMANT, CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT
        );

        BatchClaim memory decoded = wrapper.decode(encoded);

        assertBatchClaimEqual(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            CLAIMANT,
            hex"",
            hex"",
            locks,
            CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT,
            decoded
        );
    }

    /// @notice Test round trip with multiple locks and both signatures
    function test_roundTrip_multipleLocks_bothSignatures() public view {
        Lock[] memory locks = createMultipleLocks();

        bytes memory encoded = wrapper.encode(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            ALLOCATOR_SIG,
            SPONSOR_SIG,
            CLAIMANT,
            CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT
        );

        BatchClaim memory decoded = wrapper.decode(encoded);

        assertBatchClaimEqual(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            CLAIMANT,
            ALLOCATOR_SIG,
            SPONSOR_SIG,
            locks,
            CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT,
            decoded
        );
    }

    /// @notice Test round trip with multiple locks, reduced scaling factor, and zero signatures
    function test_roundTrip_multipleLocks_reducedScalingFactor_zeroSignatures() public view {
        Lock[] memory locks = createMultipleLocks();

        bytes memory encoded = wrapper.encode(
            SPONSOR, NONCE, EXPIRES, WITNESS, locks, hex"", hex"", CLAIMANT, CLAIM_REDUCTION_SCALING_FACTOR_REDUCED
        );

        BatchClaim memory decoded = wrapper.decode(encoded);

        assertBatchClaimEqual(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            CLAIMANT,
            hex"",
            hex"",
            locks,
            CLAIM_REDUCTION_SCALING_FACTOR_REDUCED,
            decoded
        );
    }

    /// @notice Test round trip with multiple locks, reduced scaling factor, and both signatures
    function test_roundTrip_multipleLocks_reducedScalingFactor_bothSignatures() public view {
        Lock[] memory locks = createMultipleLocks();

        bytes memory encoded = wrapper.encode(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            ALLOCATOR_SIG,
            SPONSOR_SIG,
            CLAIMANT,
            CLAIM_REDUCTION_SCALING_FACTOR_REDUCED
        );

        BatchClaim memory decoded = wrapper.decode(encoded);

        assertBatchClaimEqual(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            CLAIMANT,
            ALLOCATOR_SIG,
            SPONSOR_SIG,
            locks,
            CLAIM_REDUCTION_SCALING_FACTOR_REDUCED,
            decoded
        );
    }

    /// @notice Fuzz test: encode/decode round trip preserves data
    function testFuzz_encodeDecodeRoundTrip(
        address sponsor,
        uint256 nonce,
        uint256 expires,
        bytes32 witness,
        bytes32 claimant,
        uint256 scalingFactor,
        uint16 allocatorSigLength,
        uint16 sponsorSigLength,
        uint8 numLocks,
        bytes32 randomSeed
    ) public view {
        // Bound inputs to avoid overflows
        numLocks = uint8(bound(numLocks, 1, 10)); // 1 to 10 locks
        scalingFactor = bound(scalingFactor, 0.01e18, 2e18); // 1% to 200%
        // Bound signature lengths to reasonable values (0 to 500 bytes for testing)
        // Using 500 instead of 65535 to keep test execution reasonable
        allocatorSigLength = uint16(bound(allocatorSigLength, 0, 500));
        sponsorSigLength = uint16(bound(sponsorSigLength, 0, 500));

        // Create locks with safe amounts
        Lock[] memory locks = new Lock[](numLocks);
        unchecked {
            for (uint8 i = 0; i < numLocks; i++) {
                locks[i] = Lock({
                    lockTag: bytes12(uint96(i + 1)),
                    token: address(uint160(uint256(keccak256(abi.encode(i))))),
                    amount: 1e30 + uint256(i)
                });
            }
        }

        // Prepare signatures with arbitrary lengths
        bytes memory allocatorData = new bytes(allocatorSigLength);
        bytes memory sponsorSig = new bytes(sponsorSigLength);

        // Fill signatures with pseudo-random data
        for (uint256 i = 0; i < allocatorSigLength; i++) {
            allocatorData[i] = bytes1(uint8(uint256(keccak256(abi.encode(randomSeed, "allocator", i)))));
        }
        for (uint256 i = 0; i < sponsorSigLength; i++) {
            sponsorSig[i] = bytes1(uint8(uint256(keccak256(abi.encode(randomSeed, "sponsor", i)))));
        }

        // Encode
        bytes memory encoded;
        encoded =
            wrapper.encode(sponsor, nonce, expires, witness, locks, allocatorData, sponsorSig, claimant, scalingFactor);

        // Decode
        BatchClaim memory decoded = wrapper.decode(encoded);

        // Assert all fields match
        assertBatchClaimEqual(
            sponsor, nonce, expires, witness, claimant, allocatorData, sponsorSig, locks, scalingFactor, decoded
        );
    }

    /// @notice Test round trip with edge case: zero locks (should handle gracefully)
    function test_roundTrip_zeroLocks() public view {
        Lock[] memory locks = new Lock[](0);

        bytes memory encoded = wrapper.encode(
            SPONSOR, NONCE, EXPIRES, WITNESS, locks, hex"", hex"", CLAIMANT, CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT
        );

        BatchClaim memory decoded = wrapper.decode(encoded);

        assertBatchClaimEqual(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            CLAIMANT,
            hex"",
            hex"",
            locks,
            CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT,
            decoded
        );
    }

    //////////////////////////////////////////////////////////////
    // EDGE CASE & SECURITY TESTS
    //////////////////////////////////////////////////////////////

    /// @notice Test round trip with many commitments (stress test)
    function test_roundTrip_manyCommitments() public view {
        // Create 50 locks
        Lock[] memory locks = new Lock[](50);
        for (uint256 i = 0; i < 50; i++) {
            // casting to uint96 is safe because i + 1 is bounded by loop limit (50)
            locks[i] = Lock({
                // forge-lint: disable-next-line(unsafe-typecast)
                lockTag: bytes12(uint96(i + 1)),
                token: address(uint160(uint256(keccak256(abi.encode(i))))),
                amount: 1e18 * (i + 1)
            });
        }

        bytes memory encoded = wrapper.encode(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            ALLOCATOR_SIG,
            SPONSOR_SIG,
            CLAIMANT,
            CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT
        );

        BatchClaim memory decoded = wrapper.decode(encoded);

        assertBatchClaimEqual(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            CLAIMANT,
            ALLOCATOR_SIG,
            SPONSOR_SIG,
            locks,
            CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT,
            decoded
        );
    }

    /// @notice Test round trip with extreme scaling factors
    function test_roundTrip_extremeScalingFactors() public view {
        Lock[] memory locks = createSingleLock();

        // Test with very low scaling factor (1% = 0.01e18)
        bytes memory encoded1 = wrapper.encode(SPONSOR, NONCE, EXPIRES, WITNESS, locks, hex"", hex"", CLAIMANT, 0.01e18);

        BatchClaim memory decoded1 = wrapper.decode(encoded1);

        assertBatchClaimEqual(SPONSOR, NONCE, EXPIRES, WITNESS, CLAIMANT, hex"", hex"", locks, 0.01e18, decoded1);

        // Test with very high scaling factor (1000% = 10e18)
        bytes memory encoded2 = wrapper.encode(SPONSOR, NONCE, EXPIRES, WITNESS, locks, hex"", hex"", CLAIMANT, 10e18);

        BatchClaim memory decoded2 = wrapper.decode(encoded2);

        assertBatchClaimEqual(SPONSOR, NONCE, EXPIRES, WITNESS, CLAIMANT, hex"", hex"", locks, 10e18, decoded2);
    }

    /// @notice Test round trip with maximum values
    function test_roundTrip_maxValues() public view {
        Lock[] memory locks = createSingleLock();

        // Use max claimant value (address in bottom 160 bits)
        bytes32 maxClaimant = bytes32(uint256(type(uint160).max));

        bytes memory encoded = wrapper.encode(
            address(type(uint160).max),
            type(uint256).max,
            type(uint256).max,
            bytes32(type(uint256).max),
            locks,
            ALLOCATOR_SIG,
            SPONSOR_SIG,
            maxClaimant,
            CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT
        );

        BatchClaim memory decoded = wrapper.decode(encoded);

        assertBatchClaimEqual(
            address(type(uint160).max),
            type(uint256).max,
            type(uint256).max,
            bytes32(type(uint256).max),
            maxClaimant,
            ALLOCATOR_SIG,
            SPONSOR_SIG,
            locks,
            CLAIM_REDUCTION_SCALING_FACTOR_CONSTANT,
            decoded
        );
    }
}
