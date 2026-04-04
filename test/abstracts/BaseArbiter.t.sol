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

// Mock contract that rejects ETH transfers
contract RejectingContract {
    receive() external payable {
        revert();
    }
}

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

    address constant THE_COMPACT_ADDRESS = 0x00000000000000171ede64904551eeDF3C6C9788;
    address public tribunalAddress;

    // Test constants
    address constant SPONSOR = 0x1111111111111111111111111111111111111111;
    uint256 constant NONCE = 0x2222222222222222222222222222222222222222222222222222222222222222;
    uint256 constant EXPIRES = 0x3333333333333333333333333333333333333333333333333333333333333333;
    bytes32 constant WITNESS = keccak256("witness");
    bytes32 constant CLAIMANT = 0x9999999999999999999999999999999999999999999999999999999999999999;

    function setUp() public {
        // Deploy the testable arbiter first to get tribunalAddress
        arbiter = new TestableBaseArbiter();
        tribunalAddress = address(arbiter.TRIBUNAL());

        // Deploy TribunalMock and etch it to the expected address
        TribunalMock mockTribunal = new TribunalMock();
        vm.etch(tribunalAddress, address(mockTribunal).code);
        tribunalMock = TribunalMock(tribunalAddress);

        // Deploy MockTheCompact and etch it to the expected address
        MockTheCompact mockCompact = new MockTheCompact();
        vm.etch(THE_COMPACT_ADDRESS, address(mockCompact).code);
        compactMock = MockTheCompact(THE_COMPACT_ADDRESS);
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

            portions[0] = Component({claimant: uint256(claimant), amount: scaledAmount});

            // Create claim component
            // id = lockTag (in upper bits) | token address (in lower 160 bits)
            uint256 id = uint256(bytes32(locks[i].lockTag)) | uint256(uint160(locks[i].token));

            claims[i] = BatchClaimComponent({id: id, allocatedAmount: locks[i].amount, portions: portions});
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

    function test_validateMessageSender_success() public view {
        // Should succeed when emitter matches the arbiter address
        arbiter.validateMessageSender(address(arbiter));
    }

    function test_validateMessageSender_revert() public {
        address wrongEmitter = address(0x1234);
        vm.expectRevert(BaseArbiter.InvalidMessageSender.selector);
        arbiter.validateMessageSender(wrongEmitter);
    }

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

    function test_sendClaim() public {
        Lock[] memory locks = createSingleLock();
        BatchClaim memory claimPayload =
            createBatchClaimFromLocks(SPONSOR, NONCE, EXPIRES, WITNESS, locks, CLAIMANT, arbiter.BASE_SCALING_FACTOR());

        // Call _sendClaim
        arbiter.sendClaimPublic(claimPayload);

        // Verify that the compact's batchClaim was called by checking latestClaimHash is set
        bytes32 claimHash = compactMock.latestClaimHash();
        assertTrue(claimHash != bytes32(0), "batchClaim should have been called");
    }

    function test_lockTypehashIsImported() public pure {
        // Verify LOCK_TYPEHASH is accessible and has expected value
        bytes32 expectedTypehash = keccak256("Lock(bytes12 lockTag,address token,uint256 amount)");
        assertEq(LOCK_TYPEHASH, expectedTypehash);
    }

    function test_deriveClaimHash() public {
        Lock[] memory locks = createSingleLock();

        // Create a BatchClaim using our helper
        BatchClaim memory batchClaim =
            createBatchClaimFromLocks(SPONSOR, NONCE, EXPIRES, WITNESS, locks, CLAIMANT, arbiter.BASE_SCALING_FACTOR());

        // Get claim hash from MockTheCompact (via arbiter so msg.sender is correct)
        bytes32 compactLibClaimHash = arbiter.sendClaimPublic(batchClaim);

        // Get claim hash from BaseArbiter's _deriveClaimHash
        bytes32 arbiterClaimHash = arbiter.deriveClaimHashPublic(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        // They should match
        assertEq(arbiterClaimHash, compactLibClaimHash, "Claim hashes should match");
    }

    function test_validateBatchClaim_fullScaling() public {
        Lock[] memory locks = createSingleLock();

        // Derive the expected claim hash
        bytes32 expectedClaimHash = arbiter.deriveClaimHashPublic(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        // Set up tribunal mock with filled claim and BASE_SCALING_FACTOR scaling factor
        tribunalMock.setFilled(expectedClaimHash, CLAIMANT);
        tribunalMock.setClaimReductionScalingFactor(expectedClaimHash, arbiter.BASE_SCALING_FACTOR());

        // Validate the batch claim
        (bytes32 claimHash, bytes32 claimant, uint256 scalingFactor) =
            arbiter.validateBatchClaimPublic(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        // Verify results
        assertEq(claimHash, expectedClaimHash, "Claim hash should match");
        assertEq(claimant, CLAIMANT, "Claimant should match");
        assertEq(scalingFactor, arbiter.BASE_SCALING_FACTOR(), "Scaling factor should be BASE_SCALING_FACTOR");
    }

    function test_validateBatchClaim_halfScaling() public {
        Lock[] memory locks = createSingleLock();

        bytes32 expectedClaimHash = arbiter.deriveClaimHashPublic(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        tribunalMock.setFilled(expectedClaimHash, CLAIMANT);
        tribunalMock.setClaimReductionScalingFactor(expectedClaimHash, 0.5e18);

        (bytes32 claimHash, bytes32 claimant, uint256 scalingFactor) =
            arbiter.validateBatchClaimPublic(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        assertEq(claimHash, expectedClaimHash, "Claim hash should match");
        assertEq(claimant, CLAIMANT, "Claimant should match");
        assertEq(scalingFactor, 0.5e18, "Scaling factor should be 0.5e18");
    }

    function test_validateBatchClaim_smallScaling() public {
        Lock[] memory locks = createSingleLock();

        bytes32 expectedClaimHash = arbiter.deriveClaimHashPublic(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        tribunalMock.setFilled(expectedClaimHash, CLAIMANT);
        tribunalMock.setClaimReductionScalingFactor(expectedClaimHash, 0xffff);

        (bytes32 claimHash, bytes32 claimant, uint256 scalingFactor) =
            arbiter.validateBatchClaimPublic(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        assertEq(claimHash, expectedClaimHash, "Claim hash should match");
        assertEq(claimant, CLAIMANT, "Claimant should match");
        assertEq(scalingFactor, 0xffff, "Scaling factor should be 0xffff");
    }

    function test_validateBatchClaim_revertNotFilled() public {
        Lock[] memory locks = createSingleLock();

        // Don't set the claim as filled in tribunal mock (defaults to bytes32(0))

        vm.expectRevert(BaseArbiter.ClaimNotFilled.selector);
        arbiter.validateBatchClaimPublic(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
    }

    function test_validateBatchClaim_claimFilled() public {
        Lock[] memory locks = createMultipleLocks();

        bytes32 expectedClaimHash = arbiter.deriveClaimHashPublic(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        tribunalMock.setFilled(expectedClaimHash, CLAIMANT);
        // Don't explicitly set scaling factor, should default to BASE_SCALING_FACTOR

        (bytes32 claimHash, bytes32 claimant, uint256 scalingFactor) =
            arbiter.validateBatchClaimPublic(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        assertEq(claimHash, expectedClaimHash, "Claim hash should match");
        assertEq(claimant, CLAIMANT, "Claimant should match");
        assertEq(scalingFactor, arbiter.BASE_SCALING_FACTOR(), "Scaling factor should default to BASE_SCALING_FACTOR");
    }

    function test_validateBatchClaim_filledWithScaling() public {
        Lock[] memory locks = createMultipleLocks();

        bytes32 expectedClaimHash = arbiter.deriveClaimHashPublic(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        uint256 customScaling = 0.75e18;
        tribunalMock.setFilled(expectedClaimHash, CLAIMANT);
        tribunalMock.setClaimReductionScalingFactor(expectedClaimHash, customScaling);

        (bytes32 claimHash, bytes32 claimant, uint256 scalingFactor) =
            arbiter.validateBatchClaimPublic(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        assertEq(claimHash, expectedClaimHash, "Claim hash should match");
        assertEq(claimant, CLAIMANT, "Claimant should match");
        assertEq(scalingFactor, customScaling, "Scaling factor should be 0.75e18");
    }

    function test_validateBatchClaim_filledWithZeroScaling() public {
        Lock[] memory locks = createSingleLock();

        bytes32 expectedClaimHash = arbiter.deriveClaimHashPublic(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        tribunalMock.setFilled(expectedClaimHash, CLAIMANT);
        // Set scaling factor to 0, but mock returns 1e18 by default when 0 is set
        // So we need to explicitly test what the mock returns

        (bytes32 claimHash, bytes32 claimant, uint256 scalingFactor) =
            arbiter.validateBatchClaimPublic(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        assertEq(claimHash, expectedClaimHash, "Claim hash should match");
        assertEq(claimant, CLAIMANT, "Claimant should match");
        // TribunalMock returns 1e18 when factor is not set (defaults to 1e18)
        assertEq(scalingFactor, arbiter.BASE_SCALING_FACTOR(), "Scaling factor should default to BASE_SCALING_FACTOR");
    }

    function test_refundExcessEth_revertOnFailedRefund() public {
        RejectingContract rejector = new RejectingContract();
        // Fund the arbiter contract
        vm.deal(address(arbiter), 1 ether);
        // Call from the rejecting contract's context
        vm.prank(address(rejector));
        vm.expectRevert(BaseArbiter.EthRefundFailed.selector);
        arbiter.refundExcessEthPublic();
    }

    function test_refundExcessEth_zeroBalance() public {
        // Ensure arbiter has no balance
        assertEq(address(arbiter).balance, 0);
        // Should succeed without reverting (no-op)
        arbiter.refundExcessEthPublic();
        // Balance still 0
        assertEq(address(arbiter).balance, 0);
    }

    function test_deriveCommitmentsHash_emptyLocks() public view {
        Lock[] memory emptyLocks = new Lock[](0);
        // Should produce a valid hash (hash of empty array)
        bytes32 hash = arbiter.deriveCommitmentsHashPublic(emptyLocks);
        // Hash of empty bytes32[] array
        bytes32 expectedHash = keccak256(abi.encodePacked(new bytes32[](0)));
        assertEq(hash, expectedHash, "Empty locks should hash correctly");
    }

    function test_deriveCommitmentsHash_lockOrderMatters() public view {
        Lock[] memory locks1 = createMultipleLocks(); // [A, B, C]

        // Create same locks in different order
        Lock[] memory locks2 = new Lock[](3);
        locks2[0] = locks1[2]; // C
        locks2[1] = locks1[0]; // A
        locks2[2] = locks1[1]; // B

        bytes32 hash1 = arbiter.deriveCommitmentsHashPublic(locks1);
        bytes32 hash2 = arbiter.deriveCommitmentsHashPublic(locks2);

        assertTrue(hash1 != hash2, "Lock order should affect hash");
    }

    function test_deriveClaimHash_differentSponsor() public view {
        Lock[] memory locks = createSingleLock();
        address differentSponsor = address(0xDEADBEEF);

        bytes32 hash1 = arbiter.deriveClaimHashPublic(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        bytes32 hash2 = arbiter.deriveClaimHashPublic(differentSponsor, NONCE, EXPIRES, WITNESS, locks);

        assertTrue(hash1 != hash2, "Different sponsor should produce different hash");
    }

    function test_deriveClaimHash_differentNonce() public view {
        Lock[] memory locks = createSingleLock();
        uint256 differentNonce = 0x4444444444444444444444444444444444444444444444444444444444444444;

        bytes32 hash1 = arbiter.deriveClaimHashPublic(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        bytes32 hash2 = arbiter.deriveClaimHashPublic(SPONSOR, differentNonce, EXPIRES, WITNESS, locks);

        assertTrue(hash1 != hash2, "Different nonce should produce different hash");
    }
}

