// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Message} from "../../src/libraries/Message.sol";
import {Lock} from "the-compact/src/types/EIP712Types.sol";
import {BatchClaim} from "the-compact/src/types/BatchClaims.sol";
import {BatchClaimWithLocks} from "../../src/wormhole/WormholeTypes.sol";
import {WITNESS_TYPESTRING} from "tribunal/types/TribunalTypeHashes.sol";

/// @title MessageBatchSendWrapper
/// @notice Wrapper contract to call Message batch send functions in tests
/// @dev Needed because library functions use calldata/memory parameters
contract MessageBatchSendWrapper {
    function encodeBatchSend(
        bytes32[] memory claimants,
        uint256[] memory claimReductionScalingFactors,
        BatchClaimWithLocks[] calldata claims
    ) external pure returns (bytes memory) {
        return Message.encodeBatchSend(claimants, claimReductionScalingFactors, claims);
    }

    function decodeBatchSend(bytes calldata message) external pure returns (BatchClaim[] memory) {
        return Message.decodeBatchSend(message);
    }
}

/// @title MessageBatchSendTest
/// @notice Test suite for encodeBatchSend and decodeBatchSend functions
/// @dev Tests batch encoding/decoding with various configurations
contract MessageBatchSendTest is Test {
    MessageBatchSendWrapper public wrapper;

    // Test constants - Using distinctive non-zero patterns to catch encoding errors
    address constant SPONSOR_1 = 0x1111111111111111111111111111111111111111;
    address constant SPONSOR_2 = 0x2222222222222222222222222222222222222222;
    uint256 constant NONCE_1 = 0x2222222222222222222222222222222222222222222222222222222222222222;
    uint256 constant NONCE_2 = 0x4444444444444444444444444444444444444444444444444444444444444444;
    uint256 constant EXPIRES_1 = 0x3333333333333333333333333333333333333333333333333333333333333333;
    uint256 constant EXPIRES_2 = 0x5555555555555555555555555555555555555555555555555555555555555555;
    bytes32 constant WITNESS_1 = keccak256("witness1");
    bytes32 constant WITNESS_2 = keccak256("witness2");
    bytes32 constant CLAIMANT_1 = 0x9999999999999999999999999999999999999999999999999999999999999999;
    bytes32 constant CLAIMANT_2 = 0x8888888888888888888888888888888888888888888888888888888888888888;
    uint256 constant SCALING_FACTOR_FULL = 1e18;
    uint256 constant SCALING_FACTOR_HALF = 0.5e18;

    // Mock signatures
    bytes constant ALLOCATOR_SIG = hex"3333333333333333333333333333333333333333333333333333333333333333"
        hex"4444444444444444444444444444444444444444444444444444444444444444";
    bytes constant SPONSOR_SIG = hex"1111111111111111111111111111111111111111111111111111111111111111"
        hex"2222222222222222222222222222222222222222222222222222222222222222";

    function setUp() public {
        wrapper = new MessageBatchSendWrapper();
    }

    /// @notice Helper to create a single lock
    function createSingleLock() internal pure returns (Lock[] memory) {
        Lock[] memory locks = new Lock[](1);
        locks[0] = Lock({
            lockTag: bytes12(uint96(0x123456789ABC)),
            token: address(0x1111111111111111111111111111111111111111),
            amount: 1000e18
        });
        return locks;
    }

    /// @notice Helper to create multiple locks
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

    /// @notice Helper to assert BatchClaim equality
    function assertBatchClaimEqual(
        BatchClaimWithLocks memory expected,
        bytes32 expectedClaimant,
        uint256 expectedScalingFactor,
        BatchClaim memory actual
    ) internal pure {
        require(actual.sponsor == expected.sponsor, "sponsor mismatch");
        require(actual.nonce == expected.nonce, "nonce mismatch");
        require(actual.expires == expected.expires, "expires mismatch");
        require(actual.witness == expected.witness, "witness mismatch");
        require(keccak256(actual.allocatorData) == keccak256(expected.allocatorData), "allocatorData mismatch");
        require(keccak256(actual.sponsorSignature) == keccak256(expected.sponsorSignature), "sponsorSignature mismatch");
        require(
            keccak256(abi.encodePacked(actual.witnessTypestring)) == keccak256(abi.encodePacked(WITNESS_TYPESTRING)),
            "witnessTypestring mismatch"
        );

        // Verify claims
        require(actual.claims.length == expected.commitments.length, "claims length mismatch");

        for (uint256 i = 0; i < expected.commitments.length; i++) {
            uint256 expectedId =
                uint256(bytes32(expected.commitments[i].lockTag)) | uint256(uint160(expected.commitments[i].token));
            require(actual.claims[i].id == expectedId, "claim id mismatch");
            require(actual.claims[i].allocatedAmount == expected.commitments[i].amount, "allocatedAmount mismatch");
            require(actual.claims[i].portions.length == 1, "portions length should be 1");
            require(
                keccak256(abi.encodePacked(actual.claims[i].portions[0].claimant))
                    == keccak256(abi.encodePacked(expectedClaimant)),
                "claimant mismatch"
            );

            uint256 expectedScaledAmount = expectedScalingFactor == 1e18
                ? expected.commitments[i].amount
                : (expected.commitments[i].amount * expectedScalingFactor) / 1e18;
            require(actual.claims[i].portions[0].amount == expectedScaledAmount, "scaled amount mismatch");
        }
    }

    //////////////////////////////////////////////////////////////
    // ROUND TRIP TESTS
    //////////////////////////////////////////////////////////////

    /// @notice Test round trip with single claim, no signatures, no scaling
    function test_batchSend_roundTrip_singleClaim_noSignatures() public view {
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](1);
        claims[0] = BatchClaimWithLocks({
            sponsor: SPONSOR_1,
            nonce: NONCE_1,
            expires: EXPIRES_1,
            witness: WITNESS_1,
            allocatorData: hex"",
            sponsorSignature: hex"",
            commitments: createSingleLock()
        });

        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = CLAIMANT_1;

        uint256[] memory scalingFactors = new uint256[](1);
        scalingFactors[0] = SCALING_FACTOR_FULL;

        bytes memory encoded = wrapper.encodeBatchSend(claimants, scalingFactors, claims);
        BatchClaim[] memory decoded = wrapper.decodeBatchSend(encoded);

        require(decoded.length == 1, "decoded length mismatch");
        assertBatchClaimEqual(claims[0], claimants[0], scalingFactors[0], decoded[0]);
    }

    /// @notice Test round trip with single claim, with signatures
    function test_batchSend_roundTrip_singleClaim_withSignatures() public view {
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](1);
        claims[0] = BatchClaimWithLocks({
            sponsor: SPONSOR_1,
            nonce: NONCE_1,
            expires: EXPIRES_1,
            witness: WITNESS_1,
            allocatorData: ALLOCATOR_SIG,
            sponsorSignature: SPONSOR_SIG,
            commitments: createSingleLock()
        });

        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = CLAIMANT_1;

        uint256[] memory scalingFactors = new uint256[](1);
        scalingFactors[0] = SCALING_FACTOR_FULL;

        bytes memory encoded = wrapper.encodeBatchSend(claimants, scalingFactors, claims);
        BatchClaim[] memory decoded = wrapper.decodeBatchSend(encoded);

        require(decoded.length == 1, "decoded length mismatch");
        assertBatchClaimEqual(claims[0], claimants[0], scalingFactors[0], decoded[0]);
    }

    /// @notice Test round trip with single claim, with scaling factor
    function test_batchSend_roundTrip_singleClaim_withScaling() public view {
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](1);
        claims[0] = BatchClaimWithLocks({
            sponsor: SPONSOR_1,
            nonce: NONCE_1,
            expires: EXPIRES_1,
            witness: WITNESS_1,
            allocatorData: hex"",
            sponsorSignature: hex"",
            commitments: createSingleLock()
        });

        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = CLAIMANT_1;

        uint256[] memory scalingFactors = new uint256[](1);
        scalingFactors[0] = SCALING_FACTOR_HALF;

        bytes memory encoded = wrapper.encodeBatchSend(claimants, scalingFactors, claims);
        BatchClaim[] memory decoded = wrapper.decodeBatchSend(encoded);

        require(decoded.length == 1, "decoded length mismatch");
        assertBatchClaimEqual(claims[0], claimants[0], scalingFactors[0], decoded[0]);
    }

    /// @notice Test round trip with multiple claims, same configuration
    function test_batchSend_roundTrip_multipleClaims_sameConfig() public view {
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](3);

        claims[0] = BatchClaimWithLocks({
            sponsor: SPONSOR_1,
            nonce: NONCE_1,
            expires: EXPIRES_1,
            witness: WITNESS_1,
            allocatorData: ALLOCATOR_SIG,
            sponsorSignature: SPONSOR_SIG,
            commitments: createSingleLock()
        });

        claims[1] = BatchClaimWithLocks({
            sponsor: SPONSOR_1,
            nonce: NONCE_1 + 1,
            expires: EXPIRES_1,
            witness: WITNESS_1,
            allocatorData: ALLOCATOR_SIG,
            sponsorSignature: SPONSOR_SIG,
            commitments: createSingleLock()
        });

        claims[2] = BatchClaimWithLocks({
            sponsor: SPONSOR_1,
            nonce: NONCE_1 + 2,
            expires: EXPIRES_1,
            witness: WITNESS_1,
            allocatorData: ALLOCATOR_SIG,
            sponsorSignature: SPONSOR_SIG,
            commitments: createSingleLock()
        });

        bytes32[] memory claimants = new bytes32[](3);
        claimants[0] = CLAIMANT_1;
        claimants[1] = CLAIMANT_1;
        claimants[2] = CLAIMANT_1;

        uint256[] memory scalingFactors = new uint256[](3);
        scalingFactors[0] = SCALING_FACTOR_FULL;
        scalingFactors[1] = SCALING_FACTOR_FULL;
        scalingFactors[2] = SCALING_FACTOR_FULL;

        bytes memory encoded = wrapper.encodeBatchSend(claimants, scalingFactors, claims);
        BatchClaim[] memory decoded = wrapper.decodeBatchSend(encoded);

        require(decoded.length == 3, "decoded length mismatch");
        for (uint256 i = 0; i < 3; i++) {
            assertBatchClaimEqual(claims[i], claimants[i], scalingFactors[i], decoded[i]);
        }
    }

    /// @notice Test round trip with multiple claims, mixed configurations
    function test_batchSend_roundTrip_multipleClaims_mixedConfig() public view {
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](3);

        // Claim 1: With both signatures, full scaling
        claims[0] = BatchClaimWithLocks({
            sponsor: SPONSOR_1,
            nonce: NONCE_1,
            expires: EXPIRES_1,
            witness: WITNESS_1,
            allocatorData: ALLOCATOR_SIG,
            sponsorSignature: SPONSOR_SIG,
            commitments: createMultipleLocks()
        });

        // Claim 2: No signatures, half scaling
        claims[1] = BatchClaimWithLocks({
            sponsor: SPONSOR_2,
            nonce: NONCE_2,
            expires: EXPIRES_2,
            witness: WITNESS_2,
            allocatorData: hex"",
            sponsorSignature: hex"",
            commitments: createSingleLock()
        });

        // Claim 3: Only allocator signature, full scaling
        claims[2] = BatchClaimWithLocks({
            sponsor: SPONSOR_1,
            nonce: NONCE_1 + 100,
            expires: EXPIRES_1,
            witness: WITNESS_1,
            allocatorData: ALLOCATOR_SIG,
            sponsorSignature: hex"",
            commitments: createMultipleLocks()
        });

        bytes32[] memory claimants = new bytes32[](3);
        claimants[0] = CLAIMANT_1;
        claimants[1] = CLAIMANT_2;
        claimants[2] = CLAIMANT_1;

        uint256[] memory scalingFactors = new uint256[](3);
        scalingFactors[0] = SCALING_FACTOR_FULL;
        scalingFactors[1] = SCALING_FACTOR_HALF;
        scalingFactors[2] = SCALING_FACTOR_FULL;

        bytes memory encoded = wrapper.encodeBatchSend(claimants, scalingFactors, claims);
        BatchClaim[] memory decoded = wrapper.decodeBatchSend(encoded);

        require(decoded.length == 3, "decoded length mismatch");
        for (uint256 i = 0; i < 3; i++) {
            assertBatchClaimEqual(claims[i], claimants[i], scalingFactors[i], decoded[i]);
        }
    }

    /// @notice Test round trip with multiple claims, all different scaling factors
    function test_batchSend_roundTrip_multipleClaims_differentScaling() public view {
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](4);

        for (uint256 i = 0; i < 4; i++) {
            claims[i] = BatchClaimWithLocks({
                sponsor: SPONSOR_1,
                nonce: NONCE_1 + i,
                expires: EXPIRES_1,
                witness: WITNESS_1,
                allocatorData: hex"",
                sponsorSignature: hex"",
                commitments: createSingleLock()
            });
        }

        bytes32[] memory claimants = new bytes32[](4);
        for (uint256 i = 0; i < 4; i++) {
            claimants[i] = CLAIMANT_1;
        }

        uint256[] memory scalingFactors = new uint256[](4);
        scalingFactors[0] = 1e18; // 100%
        scalingFactors[1] = 0.75e18; // 75%
        scalingFactors[2] = 0.5e18; // 50%
        scalingFactors[3] = 0.25e18; // 25%

        bytes memory encoded = wrapper.encodeBatchSend(claimants, scalingFactors, claims);
        BatchClaim[] memory decoded = wrapper.decodeBatchSend(encoded);

        require(decoded.length == 4, "decoded length mismatch");
        for (uint256 i = 0; i < 4; i++) {
            assertBatchClaimEqual(claims[i], claimants[i], scalingFactors[i], decoded[i]);
        }
    }

    /// @notice Test decode reverts on message too short
    function test_batchSend_decode_revertsOnMessageTooShort() public {
        bytes memory tooShort = new bytes(16); // Less than 32 bytes (count size)

        vm.expectRevert("message too short");
        wrapper.decodeBatchSend(tooShort);
    }

    /// @notice Test empty batch (count = 0)
    function test_batchSend_roundTrip_emptyBatch() public view {
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](0);
        bytes32[] memory claimants = new bytes32[](0);
        uint256[] memory scalingFactors = new uint256[](0);

        bytes memory encoded = wrapper.encodeBatchSend(claimants, scalingFactors, claims);
        BatchClaim[] memory decoded = wrapper.decodeBatchSend(encoded);

        require(decoded.length == 0, "decoded length should be 0");
    }
}
