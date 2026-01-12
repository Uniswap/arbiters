pragma solidity ^0.8.13;

import {Vm} from "forge-std/Vm.sol";
import {MockTheCompact} from "test/mocks/MockTheCompact.sol";
import {TribunalMock} from "test/mocks/TribunalMock.sol";
import {WormholeArbiter} from "src/WormholeArbiter.sol";
import {BaseArbiter} from "src/abstracts/BaseArbiter.sol";
import {BatchClaimWithLocks, BatchPost} from "src/wormhole/WormholeTypes.sol";

import {Lock, BatchCompact} from "the-compact/src/types/EIP712Types.sol";
import {BatchClaim, BatchClaimComponent} from "the-compact/src/types/BatchClaims.sol";
import {Component} from "the-compact/src/types/Components.sol";
import {WITNESS_TYPESTRING} from "tribunal/types/TribunalTypeHashes.sol";

import {WormholeForkTest} from "wormhole-solidity-sdk/testing/WormholeForkTest.sol";
import {AdvancedWormholeOverride} from "wormhole-sdk/testing/WormholeOverride.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {CHAIN_ID_ARBITRUM, CHAIN_ID_BASE} from "wormhole-solidity-sdk/constants/Chains.sol";
import {IWormholeArbiter} from "src/interfaces/IWormholeArbiter.sol";
import {Message} from "src/libraries/Message.sol";
import {WormholeMappings} from "src/wormhole/WormholeMappings.sol";
import {CoreBridgeLib} from "wormhole-sdk/libraries/CoreBridge.sol";

// for post tests, using this as an example: https://github.com/wormhole-foundation/wormhole-scaffolding/blob/main/evm/forge-test/01_hello_world/HelloWorld.t.sol

contract WormholeArbiterPostTest is WormholeForkTest {
    /* forge-lint-disable mixed-case-variable */
    using AdvancedWormholeOverride for ICoreBridge;

    //wormhole arbiters for arbitrum and base
    WormholeArbiter public WormholeArbiterArbitrum;
    WormholeArbiter public WormholeArbiterBase;

    //tribunals for arbitrum and base
    TribunalMock public TribunalMockArbitrum;
    TribunalMock public TribunalMockBase;

    //addresses to etch the tribunal and compact mock to
    address constant THE_COMPACT_ADDRESS = 0x00000000000000171ede64904551eeDF3C6C9788;
    MockTheCompact public compactMock;

    //salt for the deterministic addresses
    bytes32 public salt = bytes32(uint256(0x1234));

    // create some mock data for the send
    uint256 constant BASE_CHAIN_ID_STANDARD = 8453;
    address constant SPONSOR = 0x1111111111111111111111111111111111111111;
    uint256 constant NONCE = 0x2222222222222222222222222222222222222222222222222222222222222222;
    uint256 constant EXPIRES = 0x3333333333333333333333333333333333333333333333333333333333333333;
    bytes32 constant WITNESS = keccak256("witness");
    bytes32 constant CLAIMANT = 0x9999999999999999999999999999999999999999999999999999999999999999;
    bytes constant ALLOCATOR_DATA = abi.encodePacked(keccak256("allocator_data"));
    bytes constant SPONSOR_SIGNATURE = abi.encodePacked(keccak256("sponsor_signature"));
    address public filler;

    // Helper function to create n locks with varying values
    function createLocks(uint256 n) internal pure returns (Lock[] memory) {
        Lock[] memory locks = new Lock[](n);
        for (uint256 i = 0; i < n; i++) {
            locks[i] = Lock({
                lockTag: bytes12(uint96(0x123456789ABC + i)), token: address(uint160(i + 1)), amount: (i + 1) * 1000e18
            });
        }
        return locks;
    }

    // Helper function to create BatchClaimWithLocks with varying fields based on index
    function createBatchClaimWithLocks(uint256 index, Lock[] memory locks)
        internal
        pure
        returns (BatchClaimWithLocks memory)
    {
        return BatchClaimWithLocks({
            sponsor: address(uint160(SPONSOR) + uint160(index)),
            nonce: NONCE + index,
            expires: EXPIRES + index,
            witness: index == 0 ? WITNESS : keccak256(abi.encodePacked("w", index + 1)),
            allocatorData: index == 0 ? bytes("") : abi.encodePacked(keccak256(abi.encodePacked("ad", index + 1))),
            sponsorSignature: index == 0 ? bytes("") : abi.encodePacked(keccak256(abi.encodePacked("ss", index + 1))),
            commitments: locks
        });
    }

    // Helper function to check claim equality using BatchClaimWithLocks struct
    function checkClaimEquality(
        bytes32 claimHash,
        BatchClaimWithLocks memory claim,
        Lock[] memory locks,
        bytes32 claimant,
        uint256 scalingFactor
    ) internal view {
        assertClaimEquality(
            compactMock.getReceivedClaim(claimHash),
            claim.sponsor,
            claim.nonce,
            claim.expires,
            claim.witness,
            claim.allocatorData,
            claim.sponsorSignature,
            locks,
            claimant,
            scalingFactor
        );
    }

    // Helper function to verify BatchClaim matches expected input data
    function assertClaimEquality(
        BatchClaim memory receivedClaim,
        address expectedSponsor,
        uint256 expectedNonce,
        uint256 expectedExpires,
        bytes32 expectedWitness,
        bytes memory expectedAllocatorData,
        bytes memory expectedSponsorSignature,
        Lock[] memory expectedLocks,
        bytes32 expectedClaimant,
        uint256 scalingFactor
    ) internal pure {
        // Direct field comparisons
        assertEq(receivedClaim.sponsor, expectedSponsor);
        assertEq(receivedClaim.nonce, expectedNonce);
        assertEq(receivedClaim.expires, expectedExpires);
        assertEq(receivedClaim.witness, expectedWitness);
        assertEq(receivedClaim.allocatorData, expectedAllocatorData);
        assertEq(receivedClaim.sponsorSignature, expectedSponsorSignature);
        assertEq(receivedClaim.witnessTypestring, WITNESS_TYPESTRING);

        // Compare Lock[] to BatchClaimComponent[]
        assertEq(receivedClaim.claims.length, expectedLocks.length);

        for (uint256 i = 0; i < expectedLocks.length; i++) {
            Lock memory lock = expectedLocks[i];
            BatchClaimComponent memory component = receivedClaim.claims[i];

            // Verify id = lockTag | token
            uint256 expectedId = uint256(bytes32(lock.lockTag)) | uint256(uint160(lock.token));
            assertEq(component.id, expectedId);

            // Verify allocatedAmount = original amount
            assertEq(component.allocatedAmount, lock.amount);

            // Verify portions - empty if cancelled (scalingFactor == 0)
            if (scalingFactor == 0) {
                assertEq(component.portions.length, 0);
            } else {
                assertEq(component.portions.length, 1);
                assertEq(component.portions[0].claimant, uint256(expectedClaimant));

                // Verify scaled amount
                uint256 expectedScaledAmount =
                    scalingFactor == 1e18 ? lock.amount : (lock.amount * scalingFactor) / 1e18;
                assertEq(component.portions[0].amount, expectedScaledAmount);
            }
        }
    }

    // Helper to call Message.encode with calldata (needed because Message.encode uses calldatacopy)
    function encodeMessageHelper(
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

    // Helper to call Message.encodeBatchPost with calldata
    function encodeBatchPostHelper(
        bytes32[] memory claimants,
        bytes32[] memory claimHashes,
        uint256[] memory scalingFactors
    ) external pure returns (bytes memory) {
        return Message.encodeBatchPost(claimants, claimHashes, scalingFactors);
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

        // Deploy WormholeArbiter at deterministic address first to get TRIBUNAL_ADDRESS
        WormholeArbiterArbitrum = new WormholeArbiter{salt: salt}();
        address TRIBUNAL_ADDRESS = WormholeArbiterArbitrum.TRIBUNAL_ADDRESS();

        // Deploy TribunalMock and set its code to TRIBUNAL_ADDRESS
        TribunalMock arbitrumTribunalMock = new TribunalMock();
        vm.etch(TRIBUNAL_ADDRESS, address(arbitrumTribunalMock).code);
        TribunalMockArbitrum = TribunalMock(TRIBUNAL_ADDRESS);

        // --- Deploy Tribunal, MockTheCompact, and WormholeArbiter on Base fork ---
        selectFork(CHAIN_ID_BASE);

        // filler address with 5 eth funding
        filler = makeAddr("filler");
        vm.deal(filler, 5 ether); // Fund it

        // Deploy WormholeArbiter at deterministic address (same TRIBUNAL_ADDRESS)
        WormholeArbiterBase = new WormholeArbiter{salt: salt}();

        // Deploy TribunalMock and set its code to TRIBUNAL_ADDRESS
        TribunalMock baseTribunalMock = new TribunalMock();
        vm.etch(TRIBUNAL_ADDRESS, address(baseTribunalMock).code);
        TribunalMockBase = TribunalMock(TRIBUNAL_ADDRESS);

        // deploy the compact mock
        MockTheCompact deployedCompactMock = new MockTheCompact();
        bytes memory compactCode = address(deployedCompactMock).code;
        vm.etch(THE_COMPACT_ADDRESS, compactCode);
        compactMock = MockTheCompact(THE_COMPACT_ADDRESS);
    }

    function test_deployments_success() public {
        // Tribunals deployed to same address on both forks
        assertEq(address(TribunalMockArbitrum), address(TribunalMockBase));
        assertTrue(address(TribunalMockArbitrum) != address(0));

        // Arbiters deployed to same address on both forks
        assertEq(address(WormholeArbiterArbitrum), address(WormholeArbiterBase));
        assertTrue(address(WormholeArbiterArbitrum) != address(0));

        // Compact mock etched to correct address
        assertEq(address(compactMock), THE_COMPACT_ADDRESS);

        // check that the filler has 5 eth
        selectFork(CHAIN_ID_ARBITRUM);
        assertEq(address(filler).balance, 5 ether);
    }

    function test_send_post() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        // create single lock + get claim hash + set in mock tribunal
        Lock[] memory locks = createLocks(1);
        bytes32 claimHash = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        TribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        // filler posts the claim
        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.post(
            BASE_CHAIN_ID_STANDARD, SPONSOR, NONCE, EXPIRES, WITNESS, locks, ALLOCATOR_DATA, SPONSOR_SIGNATURE
        );
        bytes memory encodedVaa = fetchEncodedVaa();

        // switch to base + verify claim hash not set yet
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash));

        // filler self-relays the post
        vm.prank(filler);
        WormholeArbiterBase.receivePost(encodedVaa);

        // verify claim hash is set + check received claim matches input
        assertTrue(compactMock.getClaimHash(claimHash));
        assertClaimEquality(
            compactMock.getReceivedClaim(claimHash),
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            locks,
            CLAIMANT,
            1e18
        );
    }

    function test_post_dispatch_callback() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        // create single lock + batch compact + claim hash + set in tribunal
        Lock[] memory locks = createLocks(1);
        BatchCompact memory compact = BatchCompact({
            arbiter: address(WormholeArbiterArbitrum),
            sponsor: SPONSOR,
            nonce: NONCE,
            expires: EXPIRES,
            commitments: locks
        });
        bytes32 claimHash = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        TribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        // encode post context + call dispatchCallback
        bytes memory context = WormholeArbiterArbitrum.encodePostContext(ALLOCATOR_DATA, SPONSOR_SIGNATURE);
        vm.prank(filler);
        vm.recordLogs();
        TribunalMockArbitrum.dispatchCallback(
            BASE_CHAIN_ID_STANDARD, compact, WITNESS, claimHash, CLAIMANT, 1e18, new uint256[](0), context
        );
        bytes memory encodedVaa = fetchEncodedVaa();

        // switch to base + verify claim hash not set yet
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash));

        // filler self-relays the post
        vm.prank(filler);
        WormholeArbiterBase.receivePost(encodedVaa);

        // verify claim hash is set + check received claim matches input
        assertTrue(compactMock.getClaimHash(claimHash));
        assertClaimEquality(
            compactMock.getReceivedClaim(claimHash),
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            locks,
            CLAIMANT,
            1e18
        );
    }

    function test_send_batch_post() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        // create locks + claims using helper + derive hashes + set in tribunal
        Lock[] memory locks1 = createLocks(1);
        Lock[] memory locks2 = createLocks(3);
        BatchClaimWithLocks memory claim1 = createBatchClaimWithLocks(0, locks1);
        BatchClaimWithLocks memory claim2 = createBatchClaimWithLocks(1, locks2);
        bytes32 claimHash1 = WormholeArbiterArbitrum.deriveClaimHash(
            claim1.sponsor, claim1.nonce, claim1.expires, claim1.witness, locks1
        );
        bytes32 claimHash2 = WormholeArbiterArbitrum.deriveClaimHash(
            claim2.sponsor, claim2.nonce, claim2.expires, claim2.witness, locks2
        );
        TribunalMockArbitrum.setFilled(claimHash1, CLAIMANT);
        TribunalMockArbitrum.setFilled(claimHash2, bytes32(uint256(CLAIMANT) + 1));

        // send batch post
        bytes32[] memory claimHashes = new bytes32[](2);
        claimHashes[0] = claimHash1;
        claimHashes[1] = claimHash2;
        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.batchPost(BASE_CHAIN_ID_STANDARD, claimHashes);
        bytes memory encodedVaa = fetchEncodedVaa();

        // construct claims array for relay
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](2);
        claims[0] = claim1;
        claims[1] = claim2;

        // switch to base + verify claim hashes not set yet
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash1));
        assertFalse(compactMock.getClaimHash(claimHash2));

        // filler self-relays the batch post
        vm.prank(filler);
        WormholeArbiterBase.receiveBatchPost(encodedVaa, claims);

        // verify claim hashes set + check received claims match input
        assertTrue(compactMock.getClaimHash(claimHash1));
        assertTrue(compactMock.getClaimHash(claimHash2));
        checkClaimEquality(claimHash1, claim1, locks1, CLAIMANT, 1e18);
        checkClaimEquality(claimHash2, claim2, locks2, bytes32(uint256(CLAIMANT) + 1), 1e18);
    }

    function test_send_multichain_batch_post() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        // create 4 claims using helper + set in tribunal
        Lock[][] memory allLocks = new Lock[][](4);
        BatchClaimWithLocks[] memory allClaims = new BatchClaimWithLocks[](4);
        bytes32[] memory claimHashes = new bytes32[](4);
        bytes32[] memory claimants = new bytes32[](4);
        for (uint256 i = 0; i < 4; i++) {
            allLocks[i] = createLocks(i + 1);
            allClaims[i] = createBatchClaimWithLocks(i, allLocks[i]);
            claimHashes[i] = WormholeArbiterArbitrum.deriveClaimHash(
                allClaims[i].sponsor, allClaims[i].nonce, allClaims[i].expires, allClaims[i].witness, allLocks[i]
            );
            claimants[i] = bytes32(uint256(CLAIMANT) + i);
            TribunalMockArbitrum.setFilled(claimHashes[i], claimants[i]);
        }

        // construct 2 batches (claims 0-1 and 2-3)
        bytes32[] memory claimHashesBatch1 = new bytes32[](2);
        claimHashesBatch1[0] = claimHashes[0];
        claimHashesBatch1[1] = claimHashes[1];
        bytes32[] memory claimHashesBatch2 = new bytes32[](2);
        claimHashesBatch2[0] = claimHashes[2];
        claimHashesBatch2[1] = claimHashes[3];
        BatchPost[] memory batches = new BatchPost[](2);
        batches[0] = BatchPost({
            chainId: BASE_CHAIN_ID_STANDARD, claimHashes: claimHashesBatch1, scalingFactors: new uint256[](0)
        });
        batches[1] = BatchPost({
            chainId: BASE_CHAIN_ID_STANDARD, claimHashes: claimHashesBatch2, scalingFactors: new uint256[](0)
        });

        // send multichain batch post + fetch VAAs
        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.multichainBatchPost(batches);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory encodedVaa1 = coreBridge().sign(coreBridge().fetchPublishedMessages(logs)[0]).encode();
        bytes memory encodedVaa2 = coreBridge().sign(coreBridge().fetchPublishedMessages(logs)[1]).encode();

        // construct claims arrays for relay
        BatchClaimWithLocks[] memory claims1 = new BatchClaimWithLocks[](2);
        claims1[0] = allClaims[0];
        claims1[1] = allClaims[1];
        BatchClaimWithLocks[] memory claims2 = new BatchClaimWithLocks[](2);
        claims2[0] = allClaims[2];
        claims2[1] = allClaims[3];

        // switch to base + verify claim hashes not set yet
        selectFork(CHAIN_ID_BASE);
        for (uint256 i = 0; i < 4; i++) {
            assertFalse(compactMock.getClaimHash(claimHashes[i]));
        }

        // filler self-relays first batch
        vm.prank(filler);
        WormholeArbiterBase.receiveBatchPost(encodedVaa1, claims1);
        assertTrue(compactMock.getClaimHash(claimHashes[0]));
        assertTrue(compactMock.getClaimHash(claimHashes[1]));
        assertFalse(compactMock.getClaimHash(claimHashes[2]));
        assertFalse(compactMock.getClaimHash(claimHashes[3]));

        // filler self-relays second batch + verify all claims
        vm.prank(filler);
        WormholeArbiterBase.receiveBatchPost(encodedVaa2, claims2);
        for (uint256 i = 0; i < 4; i++) {
            assertTrue(compactMock.getClaimHash(claimHashes[i]));
            checkClaimEquality(claimHashes[i], allClaims[i], allLocks[i], claimants[i], 1e18);
        }
    }

    function test_send_single_post_fees() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(10 gwei);

        // create single lock + get claim hash + set in mock tribunal
        Lock[] memory locks = createLocks(1);
        bytes32 claimHash = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        TribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        // filler posts the claim with message fee
        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.post{
            value: 10 gwei
        }(BASE_CHAIN_ID_STANDARD, SPONSOR, NONCE, EXPIRES, WITNESS, locks, ALLOCATOR_DATA, SPONSOR_SIGNATURE);
        bytes memory encodedVaa = fetchEncodedVaa();

        // check filler balance decremented by message fee
        assertEq(address(filler).balance, 5 ether - 10 gwei);

        // switch to base + verify claim hash not set yet
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash));

        // filler self-relays the post
        vm.prank(filler);
        WormholeArbiterBase.receivePost(encodedVaa);

        // verify claim hash is set + check received claim matches input
        assertTrue(compactMock.getClaimHash(claimHash));
        assertClaimEquality(
            compactMock.getReceivedClaim(claimHash),
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            locks,
            CLAIMANT,
            1e18
        );
    }

    function test_send_batch_post_fees() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(10 gwei);

        // create locks + claims using helper + derive hashes + set in tribunal
        Lock[] memory locks1 = createLocks(1);
        Lock[] memory locks2 = createLocks(3);
        BatchClaimWithLocks memory claim1 = createBatchClaimWithLocks(0, locks1);
        BatchClaimWithLocks memory claim2 = createBatchClaimWithLocks(1, locks2);
        bytes32 claimHash1 = WormholeArbiterArbitrum.deriveClaimHash(
            claim1.sponsor, claim1.nonce, claim1.expires, claim1.witness, locks1
        );
        bytes32 claimHash2 = WormholeArbiterArbitrum.deriveClaimHash(
            claim2.sponsor, claim2.nonce, claim2.expires, claim2.witness, locks2
        );
        TribunalMockArbitrum.setFilled(claimHash1, CLAIMANT);
        TribunalMockArbitrum.setFilled(claimHash2, bytes32(uint256(CLAIMANT) + 1));

        // send batch post with message fee
        bytes32[] memory claimHashes = new bytes32[](2);
        claimHashes[0] = claimHash1;
        claimHashes[1] = claimHash2;
        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.batchPost{value: 10 gwei}(BASE_CHAIN_ID_STANDARD, claimHashes);
        bytes memory encodedVaa = fetchEncodedVaa();

        // check filler balance decremented by message fee
        assertEq(address(filler).balance, 5 ether - 10 gwei);

        // construct claims array for relay
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](2);
        claims[0] = claim1;
        claims[1] = claim2;

        // switch to base + verify claim hashes not set yet
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash1));
        assertFalse(compactMock.getClaimHash(claimHash2));

        // filler self-relays the batch post
        vm.prank(filler);
        WormholeArbiterBase.receiveBatchPost(encodedVaa, claims);

        // verify claim hashes set + check received claims match input
        assertTrue(compactMock.getClaimHash(claimHash1));
        assertTrue(compactMock.getClaimHash(claimHash2));
        checkClaimEquality(claimHash1, claim1, locks1, CLAIMANT, 1e18);
        checkClaimEquality(claimHash2, claim2, locks2, bytes32(uint256(CLAIMANT) + 1), 1e18);
    }

    function test_send_multichain_batch_post_fees() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(10 gwei);

        // create 4 claims using helper + set in tribunal
        Lock[][] memory allLocks = new Lock[][](4);
        BatchClaimWithLocks[] memory allClaims = new BatchClaimWithLocks[](4);
        bytes32[] memory claimHashes = new bytes32[](4);
        bytes32[] memory claimants = new bytes32[](4);
        for (uint256 i = 0; i < 4; i++) {
            allLocks[i] = createLocks(i + 1);
            allClaims[i] = createBatchClaimWithLocks(i, allLocks[i]);
            claimHashes[i] = WormholeArbiterArbitrum.deriveClaimHash(
                allClaims[i].sponsor, allClaims[i].nonce, allClaims[i].expires, allClaims[i].witness, allLocks[i]
            );
            claimants[i] = bytes32(uint256(CLAIMANT) + i);
            TribunalMockArbitrum.setFilled(claimHashes[i], claimants[i]);
        }

        // construct 2 batches (claims 0-1 and 2-3)
        bytes32[] memory claimHashesBatch1 = new bytes32[](2);
        claimHashesBatch1[0] = claimHashes[0];
        claimHashesBatch1[1] = claimHashes[1];
        bytes32[] memory claimHashesBatch2 = new bytes32[](2);
        claimHashesBatch2[0] = claimHashes[2];
        claimHashesBatch2[1] = claimHashes[3];
        BatchPost[] memory batches = new BatchPost[](2);
        batches[0] = BatchPost({
            chainId: BASE_CHAIN_ID_STANDARD, claimHashes: claimHashesBatch1, scalingFactors: new uint256[](0)
        });
        batches[1] = BatchPost({
            chainId: BASE_CHAIN_ID_STANDARD, claimHashes: claimHashesBatch2, scalingFactors: new uint256[](0)
        });

        // send multichain batch post with message fees (2 batches x 10 gwei)
        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.multichainBatchPost{value: 20 gwei}(batches);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory encodedVaa1 = coreBridge().sign(coreBridge().fetchPublishedMessages(logs)[0]).encode();
        bytes memory encodedVaa2 = coreBridge().sign(coreBridge().fetchPublishedMessages(logs)[1]).encode();

        // check filler balance decremented by total message fees (2 x 10 gwei)
        assertEq(address(filler).balance, 5 ether - 20 gwei);

        // construct claims arrays for relay
        BatchClaimWithLocks[] memory claims1 = new BatchClaimWithLocks[](2);
        claims1[0] = allClaims[0];
        claims1[1] = allClaims[1];
        BatchClaimWithLocks[] memory claims2 = new BatchClaimWithLocks[](2);
        claims2[0] = allClaims[2];
        claims2[1] = allClaims[3];

        // switch to base + verify claim hashes not set yet
        selectFork(CHAIN_ID_BASE);
        for (uint256 i = 0; i < 4; i++) {
            assertFalse(compactMock.getClaimHash(claimHashes[i]));
        }

        // filler self-relays first batch
        vm.prank(filler);
        WormholeArbiterBase.receiveBatchPost(encodedVaa1, claims1);
        assertTrue(compactMock.getClaimHash(claimHashes[0]));
        assertTrue(compactMock.getClaimHash(claimHashes[1]));
        assertFalse(compactMock.getClaimHash(claimHashes[2]));
        assertFalse(compactMock.getClaimHash(claimHashes[3]));

        // filler self-relays second batch + verify all claims
        vm.prank(filler);
        WormholeArbiterBase.receiveBatchPost(encodedVaa2, claims2);
        for (uint256 i = 0; i < 4; i++) {
            assertTrue(compactMock.getClaimHash(claimHashes[i]));
            checkClaimEquality(claimHashes[i], allClaims[i], allLocks[i], claimants[i], 1e18);
        }
    }

    // test scaling factors: 1e18 (full), 0.5e18 (reduced), 0 (cancelled)
    function test_batch_post_scaling_factors_with_cancelation() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        // create 3 claims using helper + derive hashes + set in tribunal
        Lock[] memory locks1 = createLocks(1);
        Lock[] memory locks2 = createLocks(3);
        Lock[] memory locks3 = createLocks(1);
        BatchClaimWithLocks memory claim1 = createBatchClaimWithLocks(0, locks1);
        BatchClaimWithLocks memory claim2 = createBatchClaimWithLocks(1, locks2);
        BatchClaimWithLocks memory claim3 = createBatchClaimWithLocks(2, locks3);
        bytes32 claimHash1 = WormholeArbiterArbitrum.deriveClaimHash(
            claim1.sponsor, claim1.nonce, claim1.expires, claim1.witness, locks1
        );
        bytes32 claimHash2 = WormholeArbiterArbitrum.deriveClaimHash(
            claim2.sponsor, claim2.nonce, claim2.expires, claim2.witness, locks2
        );
        bytes32 claimHash3 = WormholeArbiterArbitrum.deriveClaimHash(
            claim3.sponsor, claim3.nonce, claim3.expires, claim3.witness, locks3
        );
        TribunalMockArbitrum.setFilled(claimHash1, CLAIMANT);
        TribunalMockArbitrum.setFilled(claimHash2, bytes32(uint256(CLAIMANT) + 1));
        TribunalMockArbitrum.setFilled(claimHash3, bytes32(uint256(CLAIMANT) + 2));

        // set scaling factors: claim1=1e18 (default), claim2=0.5e18, claim3=0 (cancelled)
        TribunalMockArbitrum.setClaimReductionScalingFactor(claimHash2, 0.5e18);
        TribunalMockArbitrum.setClaimReductionScalingFactor(claimHash3, type(uint256).max);
        assertEq(TribunalMockArbitrum.claimReductionScalingFactor(claimHash1), 1e18);
        assertEq(TribunalMockArbitrum.claimReductionScalingFactor(claimHash2), 0.5e18);
        assertEq(TribunalMockArbitrum.claimReductionScalingFactor(claimHash3), 0);

        // send batch post
        bytes32[] memory claimHashes = new bytes32[](3);
        claimHashes[0] = claimHash1;
        claimHashes[1] = claimHash2;
        claimHashes[2] = claimHash3;
        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.batchPost(BASE_CHAIN_ID_STANDARD, claimHashes);
        bytes memory encodedVaa = fetchEncodedVaa();

        // construct claims array for relay
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](3);
        claims[0] = claim1;
        claims[1] = claim2;
        claims[2] = claim3;

        // switch to base + verify claim hashes not set yet
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash1));
        assertFalse(compactMock.getClaimHash(claimHash2));
        assertFalse(compactMock.getClaimHash(claimHash3));

        // construct expected cancelled claim (empty portions)
        BatchClaimComponent[] memory expectedClaim3Components = new BatchClaimComponent[](1);
        uint256 expectedId3 = uint256(bytes32(locks3[0].lockTag)) | uint256(uint160(locks3[0].token));
        expectedClaim3Components[0] =
            BatchClaimComponent({id: expectedId3, allocatedAmount: locks3[0].amount, portions: new Component[](0)});
        BatchClaim memory expectedClaim3 = BatchClaim({
            allocatorData: claim3.allocatorData,
            sponsorSignature: claim3.sponsorSignature,
            sponsor: claim3.sponsor,
            nonce: claim3.nonce,
            expires: claim3.expires,
            witness: claim3.witness,
            witnessTypestring: WITNESS_TYPESTRING,
            claims: expectedClaim3Components
        });
        vm.expectCall(address(compactMock), abi.encodeCall(compactMock.batchClaim, (expectedClaim3)));

        // filler self-relays the batch post
        vm.prank(filler);
        WormholeArbiterBase.receiveBatchPost(encodedVaa, claims);

        // verify claim hashes set + call count + received claims match
        assertTrue(compactMock.getClaimHash(claimHash1));
        assertTrue(compactMock.getClaimHash(claimHash2));
        assertTrue(compactMock.getClaimHash(claimHash3));
        assertEq(compactMock.getCallCount(), 3);
        checkClaimEquality(claimHash1, claim1, locks1, CLAIMANT, 1e18);
        checkClaimEquality(claimHash2, claim2, locks2, bytes32(uint256(CLAIMANT) + 1), 0.5e18);
        checkClaimEquality(claimHash3, claim3, locks3, bytes32(uint256(CLAIMANT) + 2), 0);
    }

    // test for post with scaling factors and cancelation (2 seperate posts with scaling factors)
    function test_post_scaling_factors_with_cancelation() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        // === Test 1: 0.5e18 scaling factor (reduced) ===
        Lock[] memory locks1 = createLocks(1);
        bytes32 claimHash1 = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks1);
        TribunalMockArbitrum.setFilled(claimHash1, CLAIMANT);
        TribunalMockArbitrum.setClaimReductionScalingFactor(claimHash1, 0.5e18);

        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.post(
            BASE_CHAIN_ID_STANDARD, SPONSOR, NONCE, EXPIRES, WITNESS, locks1, ALLOCATOR_DATA, SPONSOR_SIGNATURE
        );
        bytes memory encodedVaa1 = fetchEncodedVaa();

        selectFork(CHAIN_ID_BASE);
        vm.prank(filler);
        WormholeArbiterBase.receivePost(encodedVaa1);

        assertTrue(compactMock.getClaimHash(claimHash1));
        assertClaimEquality(
            compactMock.getReceivedClaim(claimHash1),
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            locks1,
            CLAIMANT,
            0.5e18
        );

        // === Test 2: 0 scaling factor (cancelled - empty portions) ===
        selectFork(CHAIN_ID_ARBITRUM);
        Lock[] memory locks2 = createLocks(1);
        bytes32 claimHash2 = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE + 1, EXPIRES, WITNESS, locks2);
        TribunalMockArbitrum.setFilled(claimHash2, CLAIMANT);
        TribunalMockArbitrum.setClaimReductionScalingFactor(claimHash2, type(uint256).max); // max = cancelled = returns 0

        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.post(
            BASE_CHAIN_ID_STANDARD, SPONSOR, NONCE + 1, EXPIRES, WITNESS, locks2, ALLOCATOR_DATA, SPONSOR_SIGNATURE
        );
        bytes memory encodedVaa2 = fetchEncodedVaa();

        selectFork(CHAIN_ID_BASE);
        vm.prank(filler);
        WormholeArbiterBase.receivePost(encodedVaa2);

        assertTrue(compactMock.getClaimHash(claimHash2));
        assertClaimEquality(
            compactMock.getReceivedClaim(claimHash2),
            SPONSOR,
            NONCE + 1,
            EXPIRES,
            WITNESS,
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            locks2,
            CLAIMANT,
            0
        );
    }

    // test for dispatch post with scaling factors and cancelation (2 seperate posts with scaling factors)
    function test_dispatch_post_scaling_factors_with_cancelation() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        // === Test 1: 0.5e18 scaling factor (reduced) ===
        Lock[] memory locks1 = createLocks(1);
        BatchCompact memory compact1 = BatchCompact({
            arbiter: address(WormholeArbiterArbitrum),
            sponsor: SPONSOR,
            nonce: NONCE,
            expires: EXPIRES,
            commitments: locks1
        });
        bytes32 claimHash1 = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks1);
        TribunalMockArbitrum.setFilled(claimHash1, CLAIMANT);

        bytes memory context1 = WormholeArbiterArbitrum.encodePostContext(ALLOCATOR_DATA, SPONSOR_SIGNATURE);
        vm.prank(filler);
        vm.recordLogs();
        TribunalMockArbitrum.dispatchCallback(
            BASE_CHAIN_ID_STANDARD, compact1, WITNESS, claimHash1, CLAIMANT, 0.5e18, new uint256[](0), context1
        );
        bytes memory encodedVaa1 = fetchEncodedVaa();

        selectFork(CHAIN_ID_BASE);
        vm.prank(filler);
        WormholeArbiterBase.receivePost(encodedVaa1);

        assertTrue(compactMock.getClaimHash(claimHash1));
        assertClaimEquality(
            compactMock.getReceivedClaim(claimHash1),
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            locks1,
            CLAIMANT,
            0.5e18
        );

        // === Test 2: 0 scaling factor (cancelled - empty portions) ===
        selectFork(CHAIN_ID_ARBITRUM);
        Lock[] memory locks2 = createLocks(1);
        BatchCompact memory compact2 = BatchCompact({
            arbiter: address(WormholeArbiterArbitrum),
            sponsor: SPONSOR,
            nonce: NONCE + 1,
            expires: EXPIRES,
            commitments: locks2
        });
        bytes32 claimHash2 = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE + 1, EXPIRES, WITNESS, locks2);
        TribunalMockArbitrum.setFilled(claimHash2, CLAIMANT);

        bytes memory context2 = WormholeArbiterArbitrum.encodePostContext(ALLOCATOR_DATA, SPONSOR_SIGNATURE);
        vm.prank(filler);
        vm.recordLogs();
        TribunalMockArbitrum.dispatchCallback(
            BASE_CHAIN_ID_STANDARD, compact2, WITNESS, claimHash2, CLAIMANT, 0, new uint256[](0), context2
        );
        bytes memory encodedVaa2 = fetchEncodedVaa();

        selectFork(CHAIN_ID_BASE);
        vm.prank(filler);
        WormholeArbiterBase.receivePost(encodedVaa2);

        assertTrue(compactMock.getClaimHash(claimHash2));
        assertClaimEquality(
            compactMock.getReceivedClaim(claimHash2),
            SPONSOR,
            NONCE + 1,
            EXPIRES,
            WITNESS,
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            locks2,
            CLAIMANT,
            0
        );
    }

    ///// post test edge cases trib side /////

    // test post message calls core bridge publishMessage with the correct arguments
    function test_post_message_calls_core_bridge_publish_message() public {
        selectFork(CHAIN_ID_ARBITRUM);
        uint256 testMessageFee = 0.01 gwei;
        setMessageFee(testMessageFee);

        // create single lock + get claim hash + set in mock tribunal
        Lock[] memory locks = createLocks(1);
        bytes32 claimHash = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        TribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        // get core bridge address from WormholeMappings
        address coreBridge = WormholeMappings.getWormhole(block.chainid);

        // expected payload from Message.encode
        bytes memory expectedPayload = this.encodeMessageHelper(
            SPONSOR, NONCE, EXPIRES, WITNESS, locks, ALLOCATOR_DATA, SPONSOR_SIGNATURE, CLAIMANT, 1e18
        );

        // set up vm.expectCall for coreBridge.publishMessage
        // Signature: publishMessage(uint32 nonce, bytes memory payload, uint8 consistencyLevel)
        uint8 CONSISTENCY_LEVEL = 201;
        uint32 expectedNonce = 2; // MessagePackingType.SINGLE_POST
        vm.expectCall(
            coreBridge,
            testMessageFee,
            abi.encodeCall(ICoreBridge.publishMessage, (expectedNonce, expectedPayload, CONSISTENCY_LEVEL))
        );

        // filler posts the claim with message fee
        vm.prank(filler);
        WormholeArbiterArbitrum.post{
            value: testMessageFee
        }(BASE_CHAIN_ID_STANDARD, SPONSOR, NONCE, EXPIRES, WITNESS, locks, ALLOCATOR_DATA, SPONSOR_SIGNATURE);
    }

    // test for dispatch with invalid arbiter
    function test_post_dispatch_invalid_arbiter() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        Lock[] memory locks = createLocks(1);
        // Set arbiter to a random address instead of WormholeArbiterArbitrum
        BatchCompact memory compact = BatchCompact({
            arbiter: address(0xdead), sponsor: SPONSOR, nonce: NONCE, expires: EXPIRES, commitments: locks
        });
        bytes32 claimHash = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        bytes memory context = WormholeArbiterArbitrum.encodePostContext(ALLOCATOR_DATA, SPONSOR_SIGNATURE);

        // Call arbiter directly, pranking as TRIBUNAL_ADDRESS to pass UnauthorizedCaller check
        // Should revert with InvalidArbiter because compact.arbiter != address(WormholeArbiter)
        address tribunalAddr = WormholeArbiterArbitrum.TRIBUNAL_ADDRESS();
        vm.prank(tribunalAddr);
        vm.expectRevert(IWormholeArbiter.InvalidArbiter.selector);
        WormholeArbiterArbitrum.dispatchCallback(
            BASE_CHAIN_ID_STANDARD, compact, WITNESS, claimHash, CLAIMANT, 1e18, new uint256[](0), context
        );
    }

    // test for dispatch with invalid context
    function test_post_dispatch_invalid_context() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        Lock[] memory locks = createLocks(1);
        BatchCompact memory compact = BatchCompact({
            arbiter: address(WormholeArbiterArbitrum),
            sponsor: SPONSOR,
            nonce: NONCE,
            expires: EXPIRES,
            commitments: locks
        });
        bytes32 claimHash = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        // Empty context should revert with ContextTooShort
        bytes memory context = "";

        address tribunalAddr = WormholeArbiterArbitrum.TRIBUNAL_ADDRESS();
        vm.prank(tribunalAddr);
        vm.expectRevert(IWormholeArbiter.ContextTooShort.selector);
        WormholeArbiterArbitrum.dispatchCallback(
            BASE_CHAIN_ID_STANDARD, compact, WITNESS, claimHash, CLAIMANT, 1e18, new uint256[](0), context
        );
    }

    // test dispatch from not tribunal
    function test_post_dispatch_from_not_tribunal() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        Lock[] memory locks = createLocks(1);
        BatchCompact memory compact = BatchCompact({
            arbiter: address(WormholeArbiterArbitrum),
            sponsor: SPONSOR,
            nonce: NONCE,
            expires: EXPIRES,
            commitments: locks
        });
        bytes32 claimHash = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        bytes memory context = WormholeArbiterArbitrum.encodePostContext(ALLOCATOR_DATA, SPONSOR_SIGNATURE);

        // Call from a random address (not Tribunal) - should revert with UnauthorizedCaller
        vm.prank(filler);
        vm.expectRevert(IWormholeArbiter.UnauthorizedCaller.selector);
        WormholeArbiterArbitrum.dispatchCallback(
            BASE_CHAIN_ID_STANDARD, compact, WITNESS, claimHash, CLAIMANT, 1e18, new uint256[](0), context
        );
    }

    // test for post with invalid claim hash
    function test_post_invalid_claim_hash() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        Lock[] memory locks = createLocks(1);
        // Don't call TribunalMockArbitrum.setFilled() - claim is not filled

        vm.prank(filler);
        vm.expectRevert("Claim not filled in Tribunal");
        WormholeArbiterArbitrum.post(
            BASE_CHAIN_ID_STANDARD, SPONSOR, NONCE, EXPIRES, WITNESS, locks, ALLOCATOR_DATA, SPONSOR_SIGNATURE
        );
    }

    // test for post with invalid claimant
    function test_post_invalid_claimant() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        // Create locks + claims + set in tribunal
        Lock[] memory locks1 = createLocks(1);
        Lock[] memory locks2 = createLocks(2);
        BatchClaimWithLocks memory claim1 = createBatchClaimWithLocks(0, locks1);
        BatchClaimWithLocks memory claim2 = createBatchClaimWithLocks(1, locks2);
        bytes32 claimHash1 = WormholeArbiterArbitrum.deriveClaimHash(
            claim1.sponsor, claim1.nonce, claim1.expires, claim1.witness, locks1
        );
        bytes32 claimHash2 = WormholeArbiterArbitrum.deriveClaimHash(
            claim2.sponsor, claim2.nonce, claim2.expires, claim2.witness, locks2
        );
        TribunalMockArbitrum.setFilled(claimHash1, CLAIMANT);
        TribunalMockArbitrum.setFilled(claimHash2, bytes32(uint256(CLAIMANT) + 1));

        // Send batch post
        bytes32[] memory claimHashes = new bytes32[](2);
        claimHashes[0] = claimHash1;
        claimHashes[1] = claimHash2;
        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.batchPost(BASE_CHAIN_ID_STANDARD, claimHashes);
        bytes memory encodedVaa = fetchEncodedVaa();

        // Construct claims array with WRONG data (swap claim1 and claim2)
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](2);
        claims[0] = claim2; // Wrong! Should be claim1
        claims[1] = claim1; // Wrong! Should be claim2

        // Switch to base and try to receive - should revert with InvalidClaimHash
        selectFork(CHAIN_ID_BASE);
        vm.prank(filler);
        vm.expectRevert(IWormholeArbiter.InvalidClaimHash.selector);
        WormholeArbiterBase.receiveBatchPost(encodedVaa, claims);
    }

    // test for post with invalid fee
    function test_post_invalid_fee() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(10 gwei); // Set non-zero message fee

        Lock[] memory locks = createLocks(1);
        bytes32 claimHash = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        TribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        // Send with 0 value - not enough to pay message fee
        vm.prank(filler);
        vm.expectRevert(); // Will revert due to insufficient funds for publishMessage
        WormholeArbiterArbitrum.post(
            BASE_CHAIN_ID_STANDARD, SPONSOR, NONCE, EXPIRES, WITNESS, locks, ALLOCATOR_DATA, SPONSOR_SIGNATURE
        );
    }

    // test for batch post with no claim filled in tribunal
    function test_batch_post_no_claim_filled() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        Lock[] memory locks1 = createLocks(1);
        Lock[] memory locks2 = createLocks(2);
        BatchClaimWithLocks memory claim1 = createBatchClaimWithLocks(0, locks1);
        BatchClaimWithLocks memory claim2 = createBatchClaimWithLocks(1, locks2);

        // Only set claim1 as filled, not claim2
        bytes32 claimHash1 = WormholeArbiterArbitrum.deriveClaimHash(
            claim1.sponsor, claim1.nonce, claim1.expires, claim1.witness, locks1
        );
        bytes32 claimHash2 = WormholeArbiterArbitrum.deriveClaimHash(
            claim2.sponsor, claim2.nonce, claim2.expires, claim2.witness, locks2
        );
        TribunalMockArbitrum.setFilled(claimHash1, CLAIMANT);
        // claim2 is NOT filled

        bytes32[] memory claimHashes = new bytes32[](2);
        claimHashes[0] = claimHash1;
        claimHashes[1] = claimHash2;

        vm.prank(filler);
        vm.expectRevert(IWormholeArbiter.ClaimNotFilled.selector);
        WormholeArbiterArbitrum.batchPost(BASE_CHAIN_ID_STANDARD, claimHashes);
    }

    // test for batch post larger than max batch size
    function test_batch_post_exceeds_max_size() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        // Create 121 claims to exceed MAX_BATCH_POST_CLAIMS (120)
        uint256 numClaims = 121;
        bytes32[] memory claimHashes = new bytes32[](numClaims);

        for (uint256 i = 0; i < numClaims; i++) {
            Lock[] memory locks = createLocks(1);
            BatchClaimWithLocks memory claim = createBatchClaimWithLocks(i, locks);
            claimHashes[i] = WormholeArbiterArbitrum.deriveClaimHash(
                claim.sponsor, claim.nonce, claim.expires, claim.witness, locks
            );
            TribunalMockArbitrum.setFilled(claimHashes[i], bytes32(uint256(CLAIMANT) + i));
        }

        vm.prank(filler);
        vm.expectRevert(IWormholeArbiter.TooManyClaims.selector);
        WormholeArbiterArbitrum.batchPost(BASE_CHAIN_ID_STANDARD, claimHashes);
    }

    // test for multichain batch post with no claim filled in tribunal
    function test_multichain_batch_post_no_claim_filled() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        // First batch - filled
        Lock[] memory locks1 = createLocks(1);
        BatchClaimWithLocks memory claim1 = createBatchClaimWithLocks(0, locks1);
        bytes32 claimHash1 = WormholeArbiterArbitrum.deriveClaimHash(
            claim1.sponsor, claim1.nonce, claim1.expires, claim1.witness, locks1
        );
        TribunalMockArbitrum.setFilled(claimHash1, CLAIMANT);

        bytes32[] memory claimHashes1 = new bytes32[](1);
        claimHashes1[0] = claimHash1;

        // Second batch - NOT filled
        Lock[] memory locks2 = createLocks(2);
        BatchClaimWithLocks memory claim2 = createBatchClaimWithLocks(1, locks2);
        bytes32 claimHash2 = WormholeArbiterArbitrum.deriveClaimHash(
            claim2.sponsor, claim2.nonce, claim2.expires, claim2.witness, locks2
        );
        // claim2 is NOT filled

        bytes32[] memory claimHashes2 = new bytes32[](1);
        claimHashes2[0] = claimHash2;

        BatchPost[] memory batches = new BatchPost[](2);
        batches[0] =
            BatchPost({chainId: BASE_CHAIN_ID_STANDARD, claimHashes: claimHashes1, scalingFactors: new uint256[](0)});
        batches[1] =
            BatchPost({chainId: BASE_CHAIN_ID_STANDARD, claimHashes: claimHashes2, scalingFactors: new uint256[](0)});

        vm.prank(filler);
        vm.expectRevert(IWormholeArbiter.ClaimNotFilled.selector);
        WormholeArbiterArbitrum.multichainBatchPost(batches);
    }

    ///// post test edge cases arbiter side /////

    // test for post with invalid emitter address
    function test_post_invalid_emitter_address() public {
        selectFork(CHAIN_ID_BASE);

        // Create a valid payload
        Lock[] memory locks = createLocks(1);
        bytes memory payload = this.encodeMessageHelper(
            SPONSOR, NONCE, EXPIRES, WITNESS, locks, ALLOCATOR_DATA, SPONSOR_SIGNATURE, CLAIMANT, 1e18
        );

        // Craft a VAA with a fake emitter address (not the real arbiter address)
        bytes32 fakeEmitterAddress = bytes32(uint256(uint160(address(0xdeadbeef))));
        uint16 wormholeArbitrumChainId = WormholeMappings.toWormholeId(42161); // Arbitrum = 23

        // Set nonce to 2 (SINGLE_POST)
        coreBridge().setNonce(2);

        bytes memory encodedVaa = coreBridge().craftVaa(wormholeArbitrumChainId, fakeEmitterAddress, payload);

        // Should reject because emitter address != address(WormholeArbiterBase)
        vm.expectRevert("Message not from corresponding arbiter");
        WormholeArbiterBase.receivePost(encodedVaa);
    }

    // test for post with invalid chain ID (unsupported chain)
    function test_post_invalid_chain_id() public {
        selectFork(CHAIN_ID_BASE);

        // Create a valid payload
        Lock[] memory locks = createLocks(1);
        bytes memory payload = this.encodeMessageHelper(
            SPONSOR, NONCE, EXPIRES, WITNESS, locks, ALLOCATOR_DATA, SPONSOR_SIGNATURE, CLAIMANT, 1e18
        );

        // Craft a VAA with valid emitter but unsupported chain ID
        bytes32 realEmitterAddress = bytes32(uint256(uint160(address(WormholeArbiterBase))));
        uint16 unsupportedChainId = 99; // Not in WormholeMappings (supported: 2, 23, 30, 44)

        // Set nonce to 2 (SINGLE_POST)
        coreBridge().setNonce(2);

        bytes memory encodedVaa = coreBridge().craftVaa(unsupportedChainId, realEmitterAddress, payload);

        // Should reject because chain ID 99 is not supported
        vm.expectRevert("Unsupported chain");
        WormholeArbiterBase.receivePost(encodedVaa);
    }

    // test for batch post with invalid chain ID (unsupported chain)
    function test_batch_post_invalid_chain_id() public {
        selectFork(CHAIN_ID_BASE);

        // Create claim data for receiveBatchPost
        Lock[] memory locks = createLocks(1);
        BatchClaimWithLocks memory claim = createBatchClaimWithLocks(0, locks);

        // Create a batch post payload (just need any valid-ish payload for the test)
        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = CLAIMANT;
        bytes32[] memory claimHashes = new bytes32[](1);
        claimHashes[0] =
            WormholeArbiterBase.deriveClaimHash(claim.sponsor, claim.nonce, claim.expires, claim.witness, locks);
        uint256[] memory scalingFactors = new uint256[](1);
        scalingFactors[0] = 1e18;
        bytes memory payload = Message.encodeBatchPost(claimants, claimHashes, scalingFactors);

        // Craft a VAA with valid emitter but unsupported chain ID
        bytes32 realEmitterAddress = bytes32(uint256(uint160(address(WormholeArbiterBase))));
        uint16 unsupportedChainId = 99;

        // Set nonce to 3 (BATCH_POST)
        coreBridge().setNonce(3);

        bytes memory encodedVaa = coreBridge().craftVaa(unsupportedChainId, realEmitterAddress, payload);

        // Construct claims array for receiveBatchPost
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](1);
        claims[0] = claim;

        // Should reject because chain ID 99 is not supported
        vm.expectRevert("Unsupported chain");
        WormholeArbiterBase.receiveBatchPost(encodedVaa, claims);
    }

    // test for post with invalid nonce
    function test_post_invalid_nonce() public {
        selectFork(CHAIN_ID_BASE);

        // Create a valid payload
        Lock[] memory locks = createLocks(1);
        bytes memory payload = this.encodeMessageHelper(
            SPONSOR, NONCE, EXPIRES, WITNESS, locks, ALLOCATOR_DATA, SPONSOR_SIGNATURE, CLAIMANT, 1e18
        );

        bytes32 realEmitterAddress = bytes32(uint256(uint160(address(WormholeArbiterBase))));
        uint16 wormholeArbitrumChainId = WormholeMappings.toWormholeId(42161); // Arbitrum = 23

        // Set nonce to 0 (SINGLE_SEND) - not valid for receivePost which expects 2 (SINGLE_POST)
        coreBridge().setNonce(0);

        bytes memory encodedVaa = coreBridge().craftVaa(wormholeArbitrumChainId, realEmitterAddress, payload);

        // Should revert with InvalidMessageType because nonce 0 (SINGLE_SEND) is not valid for receivePost
        vm.expectRevert(IWormholeArbiter.InvalidMessageType.selector);
        WormholeArbiterBase.receivePost(encodedVaa);
    }

    // test for batch post with invalid claim hashes that dont match the derived claim hash
    function test_batch_post_claim_hash_mismatch() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        // Create legitimate claim and set in tribunal
        Lock[] memory locks = createLocks(1);
        BatchClaimWithLocks memory claim = createBatchClaimWithLocks(0, locks);
        bytes32 claimHash =
            WormholeArbiterArbitrum.deriveClaimHash(claim.sponsor, claim.nonce, claim.expires, claim.witness, locks);
        TribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        // Send batch post with valid claim hash
        bytes32[] memory claimHashes = new bytes32[](1);
        claimHashes[0] = claimHash;
        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.batchPost(BASE_CHAIN_ID_STANDARD, claimHashes);
        bytes memory encodedVaa = fetchEncodedVaa();

        // Switch to Base for receive tests
        selectFork(CHAIN_ID_BASE);

        // Test 1: Wrong sponsor
        {
            BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](1);
            claims[0] = claim;
            claims[0].sponsor = address(0xBAD);
            vm.expectRevert(IWormholeArbiter.InvalidClaimHash.selector);
            WormholeArbiterBase.receiveBatchPost(encodedVaa, claims);
        }

        // Test 2: Wrong nonce
        {
            BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](1);
            claims[0] = claim;
            claims[0].nonce = claim.nonce + 1;
            vm.expectRevert(IWormholeArbiter.InvalidClaimHash.selector);
            WormholeArbiterBase.receiveBatchPost(encodedVaa, claims);
        }

        // Test 3: Wrong expires
        {
            BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](1);
            claims[0] = claim;
            claims[0].expires = claim.expires + 1;
            vm.expectRevert(IWormholeArbiter.InvalidClaimHash.selector);
            WormholeArbiterBase.receiveBatchPost(encodedVaa, claims);
        }

        // Test 4: Wrong witness
        {
            BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](1);
            claims[0] = claim;
            claims[0].witness = keccak256("wrong witness");
            vm.expectRevert(IWormholeArbiter.InvalidClaimHash.selector);
            WormholeArbiterBase.receiveBatchPost(encodedVaa, claims);
        }

        // Test 5: Wrong lockTag in commitment
        {
            BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](1);
            claims[0] = claim;
            Lock[] memory wrongLocks = new Lock[](1);
            wrongLocks[0] =
                Lock({lockTag: bytes12(uint96(0xBADBADBADBAD)), token: locks[0].token, amount: locks[0].amount});
            claims[0].commitments = wrongLocks;
            vm.expectRevert(IWormholeArbiter.InvalidClaimHash.selector);
            WormholeArbiterBase.receiveBatchPost(encodedVaa, claims);
        }

        // Test 6: Wrong token in commitment
        {
            BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](1);
            claims[0] = claim;
            Lock[] memory wrongLocks = new Lock[](1);
            wrongLocks[0] = Lock({lockTag: locks[0].lockTag, token: address(0xBAD), amount: locks[0].amount});
            claims[0].commitments = wrongLocks;
            vm.expectRevert(IWormholeArbiter.InvalidClaimHash.selector);
            WormholeArbiterBase.receiveBatchPost(encodedVaa, claims);
        }

        // Test 7: Wrong amount in commitment
        {
            BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](1);
            claims[0] = claim;
            Lock[] memory wrongLocks = new Lock[](1);
            wrongLocks[0] = Lock({lockTag: locks[0].lockTag, token: locks[0].token, amount: locks[0].amount + 1});
            claims[0].commitments = wrongLocks;
            vm.expectRevert(IWormholeArbiter.InvalidClaimHash.selector);
            WormholeArbiterBase.receiveBatchPost(encodedVaa, claims);
        }

        // Test 8: Wrong number of commitments
        {
            BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](1);
            claims[0] = claim;
            Lock[] memory wrongLocks = createLocks(2);
            claims[0].commitments = wrongLocks;
            vm.expectRevert(IWormholeArbiter.InvalidClaimHash.selector);
            WormholeArbiterBase.receiveBatchPost(encodedVaa, claims);
        }
    }

    function test_batch_post_claims_array_length_mismatch() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        // Create 2 legitimate claims and set in tribunal
        Lock[] memory locks1 = createLocks(1);
        Lock[] memory locks2 = createLocks(1);
        BatchClaimWithLocks memory claim1 = createBatchClaimWithLocks(0, locks1);
        BatchClaimWithLocks memory claim2 = createBatchClaimWithLocks(1, locks2);

        bytes32 claimHash1 = WormholeArbiterArbitrum.deriveClaimHash(
            claim1.sponsor, claim1.nonce, claim1.expires, claim1.witness, locks1
        );
        bytes32 claimHash2 = WormholeArbiterArbitrum.deriveClaimHash(
            claim2.sponsor, claim2.nonce, claim2.expires, claim2.witness, locks2
        );

        TribunalMockArbitrum.setFilled(claimHash1, CLAIMANT);
        TribunalMockArbitrum.setFilled(claimHash2, CLAIMANT);

        // Send batch post with 2 valid claim hashes
        bytes32[] memory claimHashes = new bytes32[](2);
        claimHashes[0] = claimHash1;
        claimHashes[1] = claimHash2;
        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.batchPost(BASE_CHAIN_ID_STANDARD, claimHashes);
        bytes memory encodedVaa = fetchEncodedVaa();

        // Switch to Base for receive tests
        selectFork(CHAIN_ID_BASE);

        // Test 1: Too few claims (1 instead of 2)
        {
            BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](1);
            claims[0] = claim1;
            vm.expectRevert(IWormholeArbiter.ClaimsArrayLengthMismatch.selector);
            WormholeArbiterBase.receiveBatchPost(encodedVaa, claims);
        }

        // Test 2: Too many claims (3 instead of 2)
        {
            BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](3);
            claims[0] = claim1;
            claims[1] = claim2;
            claims[2] = claim1; // extra claim
            vm.expectRevert(IWormholeArbiter.ClaimsArrayLengthMismatch.selector);
            WormholeArbiterBase.receiveBatchPost(encodedVaa, claims);
        }

        // Test 3: Empty claims array
        {
            BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](0);
            vm.expectRevert(IWormholeArbiter.ClaimsArrayLengthMismatch.selector);
            WormholeArbiterBase.receiveBatchPost(encodedVaa, claims);
        }
    }

    // test batch post with a bunch of different claimants and scaling factors in a big array to test bitmap encoding
    function test_batch_post_big_array_bitmap_encoding_and_decoding() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        uint256 numClaims = 15;
        bytes32 C1 = CLAIMANT;
        bytes32 C2 = bytes32(uint256(CLAIMANT) + 1);
        bytes32 C3 = bytes32(uint256(CLAIMANT) + 2);
        bytes32 C4 = bytes32(uint256(CLAIMANT) + 3);

        // Define claimants and scaling factors for each claim
        bytes32[] memory expectedClaimants = new bytes32[](numClaims);
        uint256[] memory expectedScalingFactors = new uint256[](numClaims);

        // Claim 0-3: C1 (consecutive same claimant)
        expectedClaimants[0] = C1; // first entry, default scaling
        expectedScalingFactors[0] = 1e18;
        expectedClaimants[1] = C1; // same claimant, default scaling
        expectedScalingFactors[1] = 1e18;
        expectedClaimants[2] = C1; // same claimant, non-default
        expectedScalingFactors[2] = 0.5e18;
        expectedClaimants[3] = C1; // same claimant, non-default
        expectedScalingFactors[3] = 0.5e18;

        // Claim 4-6: C2 (new claimant)
        expectedClaimants[4] = C2; // new claimant, non-default
        expectedScalingFactors[4] = 0.5e18;
        expectedClaimants[5] = C2; // same claimant, non-default
        expectedScalingFactors[5] = 0.5e18;
        expectedClaimants[6] = C2; // same claimant, default
        expectedScalingFactors[6] = 1e18;

        // Claim 7: Back to C1 (claimant change)
        expectedClaimants[7] = C1; // back to C1, default
        expectedScalingFactors[7] = 1e18;

        // Claim 8-9: C2 again (claimant change)
        expectedClaimants[8] = C2; // back to C2, non-default
        expectedScalingFactors[8] = 0.4e18;
        expectedClaimants[9] = C2; // same claimant, default
        expectedScalingFactors[9] = 1e18;

        // Claim 10-12: C3 (new claimant)
        expectedClaimants[10] = C3; // new claimant, default
        expectedScalingFactors[10] = 1e18;
        expectedClaimants[11] = C3; // same claimant, cancelled (0 scaling)
        expectedScalingFactors[11] = 0;
        expectedClaimants[12] = C3; // same claimant, non-default
        expectedScalingFactors[12] = 0.9e18;

        // Claim 13: Back to C1 (claimant change)
        expectedClaimants[13] = C1; // back to C1, very small scaling
        expectedScalingFactors[13] = 0.1e18;

        // Claim 14: New C4 (new claimant at end)
        expectedClaimants[14] = C4; // new claimant at end, default
        expectedScalingFactors[14] = 1e18;

        // Create claims and set in tribunal
        Lock[][] memory allLocks = new Lock[][](numClaims);
        BatchClaimWithLocks[] memory allClaims = new BatchClaimWithLocks[](numClaims);
        bytes32[] memory claimHashes = new bytes32[](numClaims);

        for (uint256 i = 0; i < numClaims; i++) {
            allLocks[i] = createLocks(1);
            allClaims[i] = createBatchClaimWithLocks(i, allLocks[i]);
            claimHashes[i] = WormholeArbiterArbitrum.deriveClaimHash(
                allClaims[i].sponsor, allClaims[i].nonce, allClaims[i].expires, allClaims[i].witness, allLocks[i]
            );
            TribunalMockArbitrum.setFilled(claimHashes[i], expectedClaimants[i]);

            // Handle scaling factors (type(uint256).max in mock signals cancelled, returns 0)
            if (expectedScalingFactors[i] == 0) {
                TribunalMockArbitrum.setClaimReductionScalingFactor(claimHashes[i], type(uint256).max);
            } else if (expectedScalingFactors[i] != 1e18) {
                TribunalMockArbitrum.setClaimReductionScalingFactor(claimHashes[i], expectedScalingFactors[i]);
            }
        }

        // Send batch post
        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.batchPost(BASE_CHAIN_ID_STANDARD, claimHashes);
        bytes memory encodedVaa = fetchEncodedVaa();

        // Switch to Base and receive
        selectFork(CHAIN_ID_BASE);

        // Verify claim hashes not set yet
        for (uint256 i = 0; i < numClaims; i++) {
            assertFalse(compactMock.getClaimHash(claimHashes[i]));
        }

        // Receive batch post
        vm.prank(filler);
        WormholeArbiterBase.receiveBatchPost(encodedVaa, allClaims);

        // Verify all claims were processed correctly
        for (uint256 i = 0; i < numClaims; i++) {
            assertTrue(compactMock.getClaimHash(claimHashes[i]), "Claim hash not set");

            // Verify claimant and scaling factor were decoded correctly
            checkClaimEquality(
                claimHashes[i], allClaims[i], allLocks[i], expectedClaimants[i], expectedScalingFactors[i]
            );
        }
    }

    // test for post with invalid vaa signature
    function test_post_invalid_vaa_signature() public {
        selectFork(CHAIN_ID_BASE);

        // Create a valid payload
        Lock[] memory locks = createLocks(1);
        bytes memory payload = this.encodeMessageHelper(
            SPONSOR, NONCE, EXPIRES, WITNESS, locks, ALLOCATOR_DATA, SPONSOR_SIGNATURE, CLAIMANT, 1e18
        );

        bytes32 realEmitterAddress = bytes32(uint256(uint160(address(WormholeArbiterBase))));
        uint16 wormholeArbitrumChainId = WormholeMappings.toWormholeId(42161);

        coreBridge().setNonce(2); // SINGLE_POST

        bytes memory encodedVaa = coreBridge().craftVaa(wormholeArbitrumChainId, realEmitterAddress, payload);

        // Corrupt the signature by flipping a byte in the signature area
        // VAA structure: version(1) + guardianSetIndex(4) + sigCount(1) + signatures(66 each)
        encodedVaa[10] = bytes1(uint8(encodedVaa[10]) ^ 0xFF);

        // Should revert due to invalid signature
        vm.expectRevert(CoreBridgeLib.VerificationFailed.selector);
        WormholeArbiterBase.receivePost(encodedVaa);
    }

    // test for batch post with invalid vaa signature
    function test_batch_post_invalid_vaa_signature() public {
        selectFork(CHAIN_ID_BASE);

        // Create batch payload
        uint256 numClaims = 2;
        bytes32[] memory claimants = new bytes32[](numClaims);
        bytes32[] memory claimHashes = new bytes32[](numClaims);
        uint256[] memory scalingFactors = new uint256[](numClaims);

        for (uint256 i = 0; i < numClaims; i++) {
            claimants[i] = bytes32(uint256(CLAIMANT) + i);
            claimHashes[i] = keccak256(abi.encodePacked("claim", i));
            scalingFactors[i] = 1e18;
        }

        bytes memory payload = this.encodeBatchPostHelper(claimants, claimHashes, scalingFactors);

        bytes32 realEmitterAddress = bytes32(uint256(uint160(address(WormholeArbiterBase))));
        uint16 wormholeArbitrumChainId = WormholeMappings.toWormholeId(42161);

        coreBridge().setNonce(3); // BATCH_POST

        bytes memory encodedVaa = coreBridge().craftVaa(wormholeArbitrumChainId, realEmitterAddress, payload);

        // Corrupt the signature
        encodedVaa[10] = bytes1(uint8(encodedVaa[10]) ^ 0xFF);

        // Should revert due to invalid signature
        // Note: We don't need to provide valid claims since signature check happens first
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](numClaims);
        vm.expectRevert(CoreBridgeLib.VerificationFailed.selector);
        WormholeArbiterBase.receiveBatchPost(encodedVaa, claims);
    }
}
