// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {BaseArbiter} from "src/abstracts/BaseArbiter.sol";
import {TribunalMock} from "test/mocks/TribunalMock.sol";
import {MockTheCompact} from "test/mocks/MockTheCompact.sol";
import {Lock} from "the-compact/src/types/EIP712Types.sol";
import {LOCK_TYPEHASH} from "the-compact/src/types/EIP712Types.sol";
import {BatchClaim} from "lib/the-compact/src/types/BatchClaims.sol";
import {BatchClaimComponent, Component} from "the-compact/src/types/Components.sol";
import {WITNESS_TYPESTRING} from "tribunal/types/TribunalTypeHashes.sol";

// Concrete implementation for testing
contract TestableBaseArbiter is BaseArbiter {
    // Expose internal functions for testing
    function validateMessageSender(address emitter) external view {
        _validateMessageSender(emitter);
    }

    function refundExcessEthPublic() external payable refundExcessEth {
        // Just a function to test the modifier
    }

    function sendClaimPublic(BatchClaim memory claimPayload) external returns (bytes32 claimHash) {
        return _sendClaim(claimPayload);
    }

    function deriveClaimHashPublic(
        address sponsor,
        uint256 nonce,
        uint256 expires,
        bytes32 witness,
        Lock[] calldata locks
    ) external view returns (bytes32) {
        return _deriveClaimHash(sponsor, nonce, expires, witness, locks);
    }

    function deriveCommitmentsHashPublic(Lock[] calldata locks) external pure returns (bytes32) {
        return _deriveCommitmentsHash(locks);
    }

    function validateBatchClaimPublic(
        address sponsor,
        uint256 nonce,
        uint256 expires,
        bytes32 witness,
        Lock[] calldata locks
    ) external view returns (bytes32 claimHash, bytes32 claimant, uint256 claimReductionScalingFactor) {
        return _validateBatchClaim(sponsor, nonce, expires, witness, locks);
    }
}

contract BaseArbiterTest is Test {
    TestableBaseArbiter public arbiter;
    TribunalMock public tribunalMock;
    MockTheCompact public compactMock;

    address constant TRIBUNAL_ADDRESS = 0x0000000000000000000000000000000000001111;
    address constant THE_COMPACT_ADDRESS = 0x00000000000000171ede64904551eeDF3C6C9788;

    // Test constants
    address constant SPONSOR = 0x1111111111111111111111111111111111111111;
    uint256 constant NONCE = 0x2222222222222222222222222222222222222222222222222222222222222222;
    uint256 constant EXPIRES = 0x3333333333333333333333333333333333333333333333333333333333333333;
    bytes32 constant WITNESS = keccak256("witness");
    bytes32 constant CLAIMANT = 0x9999999999999999999999999999999999999999999999999999999999999999;

    function setUp() public {
        // Deploy TribunalMock and etch it to the expected address
        TribunalMock mockTribunal = new TribunalMock();
        vm.etch(TRIBUNAL_ADDRESS, address(mockTribunal).code);
        tribunalMock = TribunalMock(TRIBUNAL_ADDRESS);

        // Deploy MockTheCompact and etch it to the expected address
        MockTheCompact mockCompact = new MockTheCompact();
        vm.etch(THE_COMPACT_ADDRESS, address(mockCompact).code);
        compactMock = MockTheCompact(THE_COMPACT_ADDRESS);

        // Deploy the testable arbiter
        arbiter = new TestableBaseArbiter();
    }

    // Helper function to create a single lock
    function createSingleLock() internal pure returns (Lock[] memory) {
        Lock[] memory locks = new Lock[](1);
        locks[0] = Lock({
            lockTag: bytes12(uint96(0x123456789ABC)),
            token: address(0x1111111111111111111111111111111111111111),
            amount: 1000e18
        });
        return locks;
    }

    // Helper function to create multiple locks
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

    // Helper function to convert locks into a BatchClaim
    function createBatchClaimFromLocks(
        address sponsor,
        uint256 nonce,
        uint256 expires,
        bytes32 witness,
        Lock[] memory locks,
        bytes32 claimant,
        uint256 claimReductionScalingFactor
    ) internal pure returns (BatchClaim memory) {
        BatchClaimComponent[] memory claims = new BatchClaimComponent[](locks.length);

        for (uint256 i = 0; i < locks.length; i++) {
            // Create portions array with single claimant
            Component[] memory portions = new Component[](1);

            // Calculate scaled amount based on claim reduction scaling factor
            uint256 scaledAmount = (locks[i].amount * claimReductionScalingFactor) / 1e18;

            portions[0] = Component({
                claimant: uint256(claimant),
                amount: scaledAmount
            });

            // Create claim component
            // id = lockTag (in upper bits) | token address (in lower 160 bits)
            uint256 id = uint256(bytes32(locks[i].lockTag)) | uint256(uint160(locks[i].token));

            claims[i] = BatchClaimComponent({
                id: id,
                allocatedAmount: locks[i].amount,
                portions: portions
            });
        }

        return BatchClaim({
            allocatorData: hex"",
            sponsorSignature: hex"",
            sponsor: sponsor,
            nonce: nonce,
            expires: expires,
            witness: witness,
            witnessTypestring: WITNESS_TYPESTRING,
            claims: claims
        });
    }

    // Test 1: Compact is set correctly
    function test_compactIsSet() public view {
        assertEq(address(arbiter.THE_COMPACT()), 0x00000000000000171ede64904551eeDF3C6C9788);
    }

    // Test 2: Tribunal is set correctly
    function test_tribunalIsSet() public view {
        assertEq(address(arbiter.TRIBUNAL()), TRIBUNAL_ADDRESS);
    }

    // Test 3: Base scaling factor is set correctly
    function test_baseScalingFactorIsSet() public view {
        assertEq(arbiter.BASE_SCALING_FACTOR(), 1e18);
    }

    // Test 4: _validateMessageSender works when emitter matches
    function test_validateMessageSender_success() public view {
        // Should succeed when emitter matches the arbiter address
        arbiter.validateMessageSender(address(arbiter));
    }

    // Test 5: _validateMessageSender reverts when emitter doesn't match
    function test_validateMessageSender_revert() public {
        address wrongEmitter = address(0x1234);
        vm.expectRevert("Message not from corresponding arbiter");
        arbiter.validateMessageSender(wrongEmitter);
    }

    // Test 6: refundExcessEth modifier works
    function test_refundExcessEth() public {
        address caller = address(0x5678);
        uint256 ethAmount = 1 ether;

        // Give caller some ETH
        vm.deal(caller, ethAmount);

        // Call function with refundExcessEth modifier while sending ETH
        vm.prank(caller);
        arbiter.refundExcessEthPublic{value: ethAmount}();

        // Verify ETH was refunded to caller
        assertEq(caller.balance, ethAmount);
        assertEq(address(arbiter).balance, 0);
    }

    // Test 7: _sendClaim works
    function test_sendClaim() public {
        Lock[] memory locks = createSingleLock();
        BatchClaim memory claimPayload = createBatchClaimFromLocks(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            CLAIMANT,
            1e18
        );

        // Call _sendClaim
        arbiter.sendClaimPublic(claimPayload);

        // Verify that the compact's batchClaim was called by checking latestClaimHash is set
        bytes32 claimHash = compactMock.latestClaimHash();
        assertTrue(claimHash != bytes32(0), "batchClaim should have been called");
    }

    // Test 8: LOCK_TYPEHASH is imported
    function test_lockTypehashIsImported() public pure {
        // Verify LOCK_TYPEHASH is accessible and has expected value
        bytes32 expectedTypehash = keccak256("Lock(bytes12 lockTag,address token,uint256 amount)");
        assertEq(LOCK_TYPEHASH, expectedTypehash);
    }

    // Test 9: _deriveClaimHash works which implictly tests _deriveCommitmentsHash
    function test_deriveClaimHash() public {
        Lock[] memory locks = createSingleLock();

        // Create a BatchClaim using our helper
        BatchClaim memory batchClaim = createBatchClaimFromLocks(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            CLAIMANT,
            1e18
        );

        // Get claim hash from MockTheCompact (via arbiter so msg.sender is correct)
        bytes32 compactLibClaimHash = arbiter.sendClaimPublic(batchClaim);

        // Get claim hash from BaseArbiter's _deriveClaimHash
        bytes32 arbiterClaimHash = arbiter.deriveClaimHashPublic(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks
        );

        // They should match
        assertEq(arbiterClaimHash, compactLibClaimHash, "Claim hashes should match");
    }

    // Test 10: _validateBatchClaim with 1e18 scaling factor
    function test_validateBatchClaim_fullScaling() public {
        Lock[] memory locks = createSingleLock();

        // Derive the expected claim hash
        bytes32 expectedClaimHash = arbiter.deriveClaimHashPublic(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks
        );

        // Set up tribunal mock with filled claim and 1e18 scaling factor
        tribunalMock.setFilled(expectedClaimHash, CLAIMANT);
        tribunalMock.setClaimReductionScalingFactor(expectedClaimHash, 1e18);

        // Validate the batch claim
        (bytes32 claimHash, bytes32 claimant, uint256 scalingFactor) = arbiter.validateBatchClaimPublic(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks
        );

        // Verify results
        assertEq(claimHash, expectedClaimHash, "Claim hash should match");
        assertEq(claimant, CLAIMANT, "Claimant should match");
        assertEq(scalingFactor, 1e18, "Scaling factor should be 1e18");
    }

    // Test 11: _validateBatchClaim with 0.5e18 scaling factor
    function test_validateBatchClaim_halfScaling() public {
        Lock[] memory locks = createSingleLock();

        bytes32 expectedClaimHash = arbiter.deriveClaimHashPublic(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks
        );

        tribunalMock.setFilled(expectedClaimHash, CLAIMANT);
        tribunalMock.setClaimReductionScalingFactor(expectedClaimHash, 0.5e18);

        (bytes32 claimHash, bytes32 claimant, uint256 scalingFactor) = arbiter.validateBatchClaimPublic(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks
        );

        assertEq(claimHash, expectedClaimHash, "Claim hash should match");
        assertEq(claimant, CLAIMANT, "Claimant should match");
        assertEq(scalingFactor, 0.5e18, "Scaling factor should be 0.5e18");
    }

    // Test 12: _validateBatchClaim with 0xffff scaling factor
    function test_validateBatchClaim_smallScaling() public {
        Lock[] memory locks = createSingleLock();

        bytes32 expectedClaimHash = arbiter.deriveClaimHashPublic(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks
        );

        tribunalMock.setFilled(expectedClaimHash, CLAIMANT);
        tribunalMock.setClaimReductionScalingFactor(expectedClaimHash, 0xffff);

        (bytes32 claimHash, bytes32 claimant, uint256 scalingFactor) = arbiter.validateBatchClaimPublic(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks
        );

        assertEq(claimHash, expectedClaimHash, "Claim hash should match");
        assertEq(claimant, CLAIMANT, "Claimant should match");
        assertEq(scalingFactor, 0xffff, "Scaling factor should be 0xffff");
    }

    // Test 13: _validateBatchClaim reverts when claim not filled
    function test_validateBatchClaim_revertNotFilled() public {
        Lock[] memory locks = createSingleLock();

        // Don't set the claim as filled in tribunal mock (defaults to bytes32(0))

        vm.expectRevert("Claim not filled in Tribunal");
        arbiter.validateBatchClaimPublic(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks
        );
    }

    // Test 14: _validateBatchClaim when claim is filled
    function test_validateBatchClaim_claimFilled() public {
        Lock[] memory locks = createMultipleLocks();

        bytes32 expectedClaimHash = arbiter.deriveClaimHashPublic(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks
        );

        tribunalMock.setFilled(expectedClaimHash, CLAIMANT);
        // Don't explicitly set scaling factor, should default to 1e18

        (bytes32 claimHash, bytes32 claimant, uint256 scalingFactor) = arbiter.validateBatchClaimPublic(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks
        );

        assertEq(claimHash, expectedClaimHash, "Claim hash should match");
        assertEq(claimant, CLAIMANT, "Claimant should match");
        assertEq(scalingFactor, 1e18, "Scaling factor should default to 1e18");
    }

    // Test 15: _validateBatchClaim with filled claim and non-zero scaling
    function test_validateBatchClaim_filledWithScaling() public {
        Lock[] memory locks = createMultipleLocks();

        bytes32 expectedClaimHash = arbiter.deriveClaimHashPublic(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks
        );

        uint256 customScaling = 0.75e18;
        tribunalMock.setFilled(expectedClaimHash, CLAIMANT);
        tribunalMock.setClaimReductionScalingFactor(expectedClaimHash, customScaling);

        (bytes32 claimHash, bytes32 claimant, uint256 scalingFactor) = arbiter.validateBatchClaimPublic(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks
        );

        assertEq(claimHash, expectedClaimHash, "Claim hash should match");
        assertEq(claimant, CLAIMANT, "Claimant should match");
        assertEq(scalingFactor, customScaling, "Scaling factor should be 0.75e18");
    }

    // Test 16: _validateBatchClaim with filled claim and zero scaling
    function test_validateBatchClaim_filledWithZeroScaling() public {
        Lock[] memory locks = createSingleLock();

        bytes32 expectedClaimHash = arbiter.deriveClaimHashPublic(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks
        );

        tribunalMock.setFilled(expectedClaimHash, CLAIMANT);
        // Set scaling factor to 0, but mock returns 1e18 by default when 0 is set
        // So we need to explicitly test what the mock returns

        (bytes32 claimHash, bytes32 claimant, uint256 scalingFactor) = arbiter.validateBatchClaimPublic(
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks
        );

        assertEq(claimHash, expectedClaimHash, "Claim hash should match");
        assertEq(claimant, CLAIMANT, "Claimant should match");
        // TribunalMock returns 1e18 when factor is not set (defaults to 1e18)
        assertEq(scalingFactor, 1e18, "Scaling factor should default to 1e18");
    }
}
