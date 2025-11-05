pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockTheCompact} from "test/mocks/MockTheCompact.sol";
import {TribunalMock} from "test/mocks/TribunalMock.sol";
import {WormholeArbiter} from "src/WormholeArbiter.sol";
import {QuoteLib} from "lib/wormhole-solidity-sdk/src/testing/ExecutorTest.sol";
import {WormholeParams, BatchSend, BatchClaimWithLocks, BatchPost} from "src/wormhole/WormholeTypes.sol";

import {Lock, BatchCompact} from "the-compact/src/types/EIP712Types.sol";

import {WormholeForkTest} from "wormhole-solidity-sdk/testing/WormholeForkTest.sol";
import {WormholeOverride} from "wormhole-solidity-sdk/testing/WormholeOverride.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {CHAIN_ID_ARBITRUM, CHAIN_ID_BASE} from "wormhole-solidity-sdk/constants/Chains.sol";

// for post tests, using this as an example: https://github.com/wormhole-foundation/wormhole-scaffolding/blob/main/evm/forge-test/01_hello_world/HelloWorld.t.sol

contract WormholeArbiterPostTest is WormholeForkTest {
    using WormholeOverride for ICoreBridge;

    //wormhole arbiters for arbitrum and base
    WormholeArbiter public WormholeArbiterArbitrum;
    WormholeArbiter public WormholeArbiterBase;

    //tribunals for arbitrum and base
    TribunalMock public TribunalMockArbitrum;
    TribunalMock public TribunalMockBase;

    //addresses to etch the tribunal and compact mock to
    address constant TRIBUNAL_ADDRESS = 0x0000000000000000000000000000000000001111;
    address constant THE_COMPACT_ADDRESS = 0x00000000000000171ede64904551eeDF3C6C9788;
    MockTheCompact public compactMock;

    //salt for the deterministic addresses
    bytes32 public salt = bytes32(uint256(0x1234));

    // create some mock data for the send
    uint256 constant BASE_CHAIN_ID_STANDARD = 8453;

    // claim data
    address constant SPONSOR = 0x1111111111111111111111111111111111111111;
    uint256 constant NONCE = 0x2222222222222222222222222222222222222222222222222222222222222222;
    uint256 constant EXPIRES = 0x3333333333333333333333333333333333333333333333333333333333333333;
    bytes32 constant WITNESS = keccak256("witness");
    bytes32 constant CLAIMANT = 0x9999999999999999999999999999999999999999999999999999999999999999;
    address public filler;

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
    function setUp() public override {

        //set up the forks
        setUpFork(CHAIN_ID_ARBITRUM, vm.envString("ARBITRUM_RPC_URL"));
        setUpFork(CHAIN_ID_BASE, vm.envString("BASE_RPC_URL"));

        // --- Deploy Tribunal and WormholeArbiter on Arbitrum fork ---
        selectFork(CHAIN_ID_ARBITRUM);

        // filler address with 5 eth funding
        filler = makeAddr("filler");
        vm.deal(filler, 5 ether); // Fund it

        // Deploy TribunalMock and set its code to TRIBUNAL_ADDRESS
        TribunalMock arbitrumTribunalMock = new TribunalMock();
        vm.etch(TRIBUNAL_ADDRESS, address(arbitrumTribunalMock).code);
        TribunalMockArbitrum = TribunalMock(TRIBUNAL_ADDRESS);

        // Deploy WormholeArbiter at deterministic address
        WormholeArbiterArbitrum = new WormholeArbiter{salt: salt}();

        // --- Deploy Tribunal, MockTheCompact, and WormholeArbiter on Base fork ---
        selectFork(CHAIN_ID_BASE);

        // filler address with 5 eth funding
        filler = makeAddr("filler");
        vm.deal(filler, 5 ether); // Fund it

        // Deploy TribunalMock and set its code to TRIBUNAL_ADDRESS
        TribunalMock baseTribunalMock = new TribunalMock();
        vm.etch(TRIBUNAL_ADDRESS, address(baseTribunalMock).code);
        TribunalMockBase = TribunalMock(TRIBUNAL_ADDRESS);

        // Deploy WormholeArbiter at deterministic address
        WormholeArbiterBase = new WormholeArbiter{salt: salt}();

        // deploy the compact mock
        MockTheCompact deployedCompactMock = new MockTheCompact();
        bytes memory compactCode = address(deployedCompactMock).code;
        vm.etch(THE_COMPACT_ADDRESS, compactCode);
        compactMock = MockTheCompact(THE_COMPACT_ADDRESS);

    }

    function test_deployments_success() public view {
        //assert that the tribunals are deployed to the same address on both forks
        assertEq(address(TribunalMockArbitrum), TRIBUNAL_ADDRESS);
        assertEq(address(TribunalMockBase), TRIBUNAL_ADDRESS);

        //assert that the arbiters are deployed to the same address on both forks
        assertEq(address(WormholeArbiterArbitrum), address(WormholeArbiterBase));
        assertTrue(address(WormholeArbiterArbitrum) != address(0));

        //assert that the compact mock is etched to the Compact address 
        assertEq(address(compactMock), THE_COMPACT_ADDRESS);
    }

    // test full e2e send and claim flow making sure 
    // TODO: check for expected calls emits on the lower level contracts
    function test_send_post() public {

        // set to arbitrum
        selectFork(CHAIN_ID_ARBITRUM);

        // set message fees to 0
        setMessageFee(0 gwei);

        //get claim hash
        bytes32 claimHash = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, createSingleLock());

        //set claim hash in mock tribunal
        TribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        //create single lock
        Lock[] memory locks = createSingleLock();

        //send post
        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.post(
            BASE_CHAIN_ID_STANDARD,
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            bytes(""),
            bytes("")
        );
        bytes memory encodedVaa = fetchEncodedVaa();

        // Switch to base and verify claim hash is not set yet
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash));

        // Switch back to arbitrum to execute the relay
        selectFork(CHAIN_ID_ARBITRUM);

        //filler self relays the post
        selectFork(CHAIN_ID_BASE);
        vm.prank(filler);
        vm.expectCall(address(WormholeArbiterBase), abi.encodeWithSignature("receivePost(bytes)"), 1);
        WormholeArbiterBase.receivePost(encodedVaa);

        selectFork(CHAIN_ID_BASE);

        //check that the claim hash is set as marked in the mock compact
        assertTrue(compactMock.getClaimHash(claimHash));
    }

    function test_send_dispatch_callback() public {
        // set to arbitrum
        selectFork(CHAIN_ID_ARBITRUM);

        // set message fees to 0
        setMessageFee(0 gwei);

        // create single lock
        Lock[] memory locks = createSingleLock();

        // create BatchCompact
        BatchCompact memory compact = BatchCompact({
            arbiter: address(WormholeArbiterArbitrum),
            sponsor: SPONSOR,
            nonce: NONCE,
            expires: EXPIRES,
            commitments: locks
        });

        // get claim hash
        bytes32 claimHash = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        // set claim hash in mock tribunal
        TribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        // encode post context (no quotes or gas params needed for post)
        bytes memory context = WormholeArbiterArbitrum.encodePostContext(
            bytes(""),
            bytes("")
        );

        // call dispatchCallback on tribunal
        // TODO check for expected emits
        vm.prank(filler);
        vm.recordLogs();
        TribunalMockArbitrum.dispatchCallback(
            BASE_CHAIN_ID_STANDARD,
            compact,
            WITNESS,
            claimHash,
            CLAIMANT,
            1e18,
            new uint256[](0),
            context
        );

        // Fetch the VAA
        bytes memory encodedVaa = fetchEncodedVaa();

        // Switch to base and verify claim hash is not set yet
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash));

        // Set expectation for 1 call to arbiter receivePost
        vm.expectCall(address(WormholeArbiterBase), abi.encodeWithSignature("receivePost(bytes)"), 1);

        // Filler self-relays the post
        vm.prank(filler);
        WormholeArbiterBase.receivePost(encodedVaa);

        // check that the claim hash is set as marked in the mock compact
        assertTrue(compactMock.getClaimHash(claimHash));
    }

    // TODO will need to verify correct derivation of locks and claims in function itself for scaling factor
    function test_send_batch_post() public {
        // set to arbitrum
        selectFork(CHAIN_ID_ARBITRUM);

        // set message fees to 0
        setMessageFee(0 gwei);

        // Create 2 batch claims with different data
        Lock[] memory locks1 = createSingleLock();
        Lock[] memory locks2 = createMultipleLocks();

        // Create claim 1
        uint256 nonce1 = NONCE;
        bytes32 witness1 = WITNESS;
        bytes32 claimHash1 = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, nonce1, EXPIRES, witness1, locks1);
        TribunalMockArbitrum.setFilled(claimHash1, CLAIMANT);

        // Create claim 2
        uint256 nonce2 = NONCE + 1;
        bytes32 witness2 = keccak256("witness2");
        bytes32 claimHash2 = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, nonce2, EXPIRES, witness2, locks2);
        TribunalMockArbitrum.setFilled(claimHash2, CLAIMANT);

        // Construct claim hash array for batch
        bytes32[] memory claimHashes = new bytes32[](2);
        claimHashes[0] = claimHash1;
        claimHashes[1] = claimHash2;

        // Send batch post
        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.batchPost(BASE_CHAIN_ID_STANDARD, claimHashes);

        // Fetch the VAA
        bytes memory encodedVaa = fetchEncodedVaa();

        // Construct BatchClaimWithLocks array for relay
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](2);
        claims[0] = BatchClaimWithLocks({
            sponsor: SPONSOR,
            nonce: nonce1,
            expires: EXPIRES,
            witness: witness1,
            allocatorData: bytes(""),
            sponsorSignature: bytes(""),
            commitments: locks1
        });
        claims[1] = BatchClaimWithLocks({
            sponsor: SPONSOR,
            nonce: nonce2,
            expires: EXPIRES,
            witness: witness2,
            allocatorData: bytes(""),
            sponsorSignature: bytes(""),
            commitments: locks2
        });

        // Switch to base and verify claim hashes are not set yet
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash1));
        assertFalse(compactMock.getClaimHash(claimHash2));

        // Set expectation for 1 call to arbiter receiveBatchPost
        vm.expectCall(
            address(WormholeArbiterBase),
            abi.encodeCall(WormholeArbiterBase.receiveBatchPost, (encodedVaa, claims))
        );

        // Filler self-relays the batch post
        vm.prank(filler);
        WormholeArbiterBase.receiveBatchPost(encodedVaa, claims);

        // Check that both claim hashes are set as marked in the mock compact
        assertTrue(compactMock.getClaimHash(claimHash1));
        assertTrue(compactMock.getClaimHash(claimHash2));
    }

    function test_send_multichain_batch_post() public {
        // set to arbitrum
        selectFork(CHAIN_ID_ARBITRUM);

        // set message fees to 0
        setMessageFee(0 gwei);

        // Create 4 claims with different data
        Lock[] memory locks1 = createSingleLock();
        Lock[] memory locks2 = createMultipleLocks();
        Lock[] memory locks3 = createSingleLock();
        Lock[] memory locks4 = createMultipleLocks();

        // Create claim 1
        uint256 nonce1 = NONCE;
        bytes32 witness1 = WITNESS;
        bytes32 claimHash1 = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, nonce1, EXPIRES, witness1, locks1);
        TribunalMockArbitrum.setFilled(claimHash1, CLAIMANT);

        // Create claim 2
        uint256 nonce2 = NONCE + 1;
        bytes32 witness2 = keccak256("witness2");
        bytes32 claimHash2 = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, nonce2, EXPIRES, witness2, locks2);
        TribunalMockArbitrum.setFilled(claimHash2, CLAIMANT);

        // Create claim 3
        uint256 nonce3 = NONCE + 2;
        bytes32 witness3 = keccak256("witness3");
        bytes32 claimHash3 = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, nonce3, EXPIRES, witness3, locks3);
        TribunalMockArbitrum.setFilled(claimHash3, CLAIMANT);

        // Create claim 4
        uint256 nonce4 = NONCE + 3;
        bytes32 witness4 = keccak256("witness4");
        bytes32 claimHash4 = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, nonce4, EXPIRES, witness4, locks4);
        TribunalMockArbitrum.setFilled(claimHash4, CLAIMANT);

        // Construct first batch with claims 1 and 2
        bytes32[] memory claimHashes1 = new bytes32[](2);
        claimHashes1[0] = claimHash1;
        claimHashes1[1] = claimHash2;

        // Construct second batch with claims 3 and 4
        bytes32[] memory claimHashes2 = new bytes32[](2);
        claimHashes2[0] = claimHash3;
        claimHashes2[1] = claimHash4;

        // Construct BatchPost array - both targeting BASE chain
        BatchPost[] memory batches = new BatchPost[](2);
        batches[0] = BatchPost({
            chainId: BASE_CHAIN_ID_STANDARD,
            claimHashes: claimHashes1,
            scalingFactors: new uint256[](0)
        });
        batches[1] = BatchPost({
            chainId: BASE_CHAIN_ID_STANDARD,
            claimHashes: claimHashes2,
            scalingFactors: new uint256[](0)
        });

        // Send multichain batch post
        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.multichainBatchPost(batches);

        // Get recorded logs once to fetch multiple VAAs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Fetch both VAAs from the logs (index [0] and [1])
        bytes memory encodedVaa1 = coreBridge().sign(
            coreBridge().fetchPublishedMessages(logs)[0]
        ).encode();
        bytes memory encodedVaa2 = coreBridge().sign(
            coreBridge().fetchPublishedMessages(logs)[1]
        ).encode();

        // Construct BatchClaimWithLocks arrays for relay
        BatchClaimWithLocks[] memory claims1 = new BatchClaimWithLocks[](2);
        claims1[0] = BatchClaimWithLocks({
            sponsor: SPONSOR,
            nonce: nonce1,
            expires: EXPIRES,
            witness: witness1,
            allocatorData: bytes(""),
            sponsorSignature: bytes(""),
            commitments: locks1
        });
        claims1[1] = BatchClaimWithLocks({
            sponsor: SPONSOR,
            nonce: nonce2,
            expires: EXPIRES,
            witness: witness2,
            allocatorData: bytes(""),
            sponsorSignature: bytes(""),
            commitments: locks2
        });

        BatchClaimWithLocks[] memory claims2 = new BatchClaimWithLocks[](2);
        claims2[0] = BatchClaimWithLocks({
            sponsor: SPONSOR,
            nonce: nonce3,
            expires: EXPIRES,
            witness: witness3,
            allocatorData: bytes(""),
            sponsorSignature: bytes(""),
            commitments: locks3
        });
        claims2[1] = BatchClaimWithLocks({
            sponsor: SPONSOR,
            nonce: nonce4,
            expires: EXPIRES,
            witness: witness4,
            allocatorData: bytes(""),
            sponsorSignature: bytes(""),
            commitments: locks4
        });

        // Switch to base and verify all claim hashes are not set yet
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash1));
        assertFalse(compactMock.getClaimHash(claimHash2));
        assertFalse(compactMock.getClaimHash(claimHash3));
        assertFalse(compactMock.getClaimHash(claimHash4));

        // Set expectation for 2 calls to arbiter receiveBatchPost (one per batch)
        vm.expectCall(
            address(WormholeArbiterBase),
            abi.encodeCall(WormholeArbiterBase.receiveBatchPost, (encodedVaa1, claims1))
        );
        vm.expectCall(
            address(WormholeArbiterBase),
            abi.encodeCall(WormholeArbiterBase.receiveBatchPost, (encodedVaa2, claims2))
        );

        // Filler self-relays both batch posts
        vm.prank(filler);
        WormholeArbiterBase.receiveBatchPost(encodedVaa1, claims1);

        // Check that all 4 claim hashes are set as marked in the mock compact
        assertTrue(compactMock.getClaimHash(claimHash1));
        assertTrue(compactMock.getClaimHash(claimHash2));
        assertFalse(compactMock.getClaimHash(claimHash3));
        assertFalse(compactMock.getClaimHash(claimHash4));

        vm.prank(filler);
        WormholeArbiterBase.receiveBatchPost(encodedVaa2, claims2);

        // Check that all 4 claim hashes are set as marked in the mock compact
        assertTrue(compactMock.getClaimHash(claimHash1));
        assertTrue(compactMock.getClaimHash(claimHash2));
        assertTrue(compactMock.getClaimHash(claimHash3));
        assertTrue(compactMock.getClaimHash(claimHash4));
    }

    function test_send_single_post_fees() public {
    }

    function test_send_batch_post_fees() public {
    }

    function test_send_multichain_batch_post_fees() public {
    }

    ///// post test edge cases trib side /////

    // test for dispatch with invalid arbiter
    function test_post_dispatch_invalid_arbiter() public {
    }

    // test for dispatch with invalid context
    function test_post_dispatch_invalid_context() public {
    }

    // test for post with invalid claim hash
    function test_post_invalid_claim_hash() public {
    }

    // test for post with invalid claimant
    function test_post_invalid_claimant() public {
    }

    // test for post with invalid fee
    function test_post_invalid_fee() public {
    }

    // test for batch post with no claim filled in tribunal
    function test_batch_post_no_claim_filled() public {
    }

    // test for batch post larger than max batch size
    function test_batch_post_exceeds_max_size() public {
    }

    // test for batch post with invalid fee for publishing (WormholeExecutor.sol)
    function test_batch_post_invalid_fee_publishing() public {
    }

    // test for multichain batch post with no claim filled in tribunal
    function test_multichain_batch_post_no_claim_filled() public {
    }

    // test for multichain batch post with invalid fee for publishing (WormholeExecutor.sol)
    function test_multichain_batch_post_invalid_fee_publishing() public {
    }

    ///// post test edge cases arbiter side /////

    // test for post with invalid emitter address
    function test_post_invalid_emitter_address() public {
    }

    // test for post with invalid nonce
    function test_post_invalid_nonce() public {
    }

    // test for batch post with invalid claim hashes that dont match the derived claim hash
    function test_batch_post_claim_hash_mismatch() public {
    }

    // test to make sure batch post is correctly applying scaling factors
    function test_batch_post_scaling_factors() public {
    }

    // test to make sure batch post is correctly applying claimants
    function test_batch_post_claimants() public {
    }

}
