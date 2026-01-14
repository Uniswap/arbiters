pragma solidity ^0.8.13;

import {MockTheCompact} from "test/mocks/MockTheCompact.sol";
import {TribunalMock} from "test/mocks/TribunalMock.sol";
import {WormholeArbiter} from "src/WormholeArbiter.sol";
import {IWormholeArbiter} from "src/interfaces/IWormholeArbiter.sol";
import {QuoteLib} from "lib/wormhole-solidity-sdk/src/testing/ExecutorTest.sol";
import {WormholeParams, BatchSend, BatchClaimWithLocks} from "src/wormhole/WormholeTypes.sol";
import {BatchClaim} from "the-compact/src/types/BatchClaims.sol";
import {BatchClaimComponent} from "the-compact/src/types/Components.sol";
import {Lock, BatchCompact} from "the-compact/src/types/EIP712Types.sol";
import {WITNESS_TYPESTRING} from "tribunal/types/TribunalTypeHashes.sol";
import {ExecutorTest} from "wormhole-solidity-sdk/testing/ExecutorTest.sol";
import {CHAIN_ID_ARBITRUM, CHAIN_ID_BASE} from "wormhole-solidity-sdk/constants/Chains.sol";
import {RequestLib} from "wormhole-sdk/Executor/Request.sol";
import {RelayInstructionLib} from "wormhole-sdk/Executor/RelayInstruction.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {IExecutor} from "wormhole-sdk/interfaces/IExecutor.sol";
import {Message} from "src/libraries/Message.sol";
import {WormholeMappings} from "src/wormhole/WormholeMappings.sol";
import {AdvancedWormholeOverride} from "wormhole-sdk/testing/WormholeOverride.sol";
import {CoreBridgeLib} from "wormhole-sdk/libraries/CoreBridge.sol";

// to understand how these tests work, see the example at: https://github.com/wormhole-foundation/wormhole-solidity-sdk/blob/main/test/Executor.t.sol
// Similar to the example, this test uses the executor test harness from the wormhole-solidity-sdk at lib/wormhole-solidity-sdk/src/testing/ExecutorTest.sol
// it forks arbitrum and base, deploys the arbiters and tribunals, and then tests the send flow on both forks.
// the ExecutorTest harness deals with the execution of the relay and the verification of the VAA and overwrites
// the coreBridge to a new set of Guardian keys to allow signing the VAA with the new guardian keys.

contract WormholeArbiterTest is ExecutorTest {
    /* forge-lint-disable mixed-case-variable */
    using AdvancedWormholeOverride for ICoreBridge;

    WormholeArbiter public wormholeArbiterArbitrum;
    WormholeArbiter public wormholeArbiterBase;

    TribunalMock public tribunalMockArbitrum;
    TribunalMock public tribunalMockBase;

    MockTheCompact public compactMock;
    address constant THE_COMPACT_ADDRESS = 0x00000000000000171ede64904551eeDF3C6C9788; //compact address to etch to

    // constants plus mock data for the send
    bytes32 public salt = bytes32(uint256(0x1234));
    uint256 constant BASE_CHAIN_ID_STANDARD = 8453;
    uint128 constant GAS_LIMIT = 5_000_000;
    address constant SPONSOR = 0x1111111111111111111111111111111111111111;
    uint256 constant NONCE = 0x2222222222222222222222222222222222222222222222222222222222222222;
    uint256 constant EXPIRES = 0x3333333333333333333333333333333333333333333333333333333333333333;
    bytes32 constant CLAIMANT = 0x8888888888888888888888888888888888888888888888888888888888888888;
    bytes32 constant WITNESS = keccak256("witness");
    bytes constant ALLOCATOR_DATA = abi.encodePacked(keccak256("allocator_data"));
    bytes constant SPONSOR_SIGNATURE = abi.encodePacked(keccak256("sponsor_signature"));

    // quote data
    bytes public quote;
    uint256 public quoteCost;
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
    ) internal {
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
    ) internal {
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

    // helper function to craft a signed quote for the send test
    // and return the total cost of the quote
    function craftSignedQuote(uint16 dstChain, uint128 gasLimit)
        internal
        view
        virtual
        returns (bytes memory signedQuote, uint256 totalCost)
    {
        uint64 fee = 1e9;
        uint64 expiryTime = uint64(block.timestamp + 1 hours);

        signedQuote = QuoteLib.signAndPackQuote(
            QuoteLib.encodeV1Quote(
                quoter,
                payee,
                chainId(),
                dstChain,
                expiryTime,
                fee, // baseFee
                fee, // destinationGasPrice
                fee, // sourcePrice
                fee // destinationPrice
            ),
            quoterSecret
        );

        // Cost: ((destGasPrice × gasLimit × destPrice) / srcPrice) + baseFee
        // All prices = fee, so: (gasLimit × fee) + fee
        totalCost = uint256(gasLimit) * fee + fee;
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

    // Helper to call Message.encodeBatchSend with calldata
    function encodeBatchSendHelper(
        bytes32[] memory claimants,
        uint256[] memory claimReductionScalingFactors,
        BatchClaimWithLocks[] calldata claims
    ) external pure returns (bytes memory) {
        return Message.encodeBatchSend(claimants, claimReductionScalingFactors, claims);
    }

    function setUp() public override {
        setUpFork(CHAIN_ID_ARBITRUM, vm.envString("ARBITRUM_RPC_URL"));
        setUpFork(CHAIN_ID_BASE, vm.envString("BASE_RPC_URL"));

        selectFork(CHAIN_ID_ARBITRUM);

        filler = makeAddr("filler");
        vm.deal(filler, 5 ether);

        // deploy wormhole arbiter + etch tribunal with TribunalMock on Arb
        wormholeArbiterArbitrum = new WormholeArbiter{salt: salt}();
        // forge-lint: disable-next-line(mixed-case-variable)
        address TRIBUNAL_ADDRESS = wormholeArbiterArbitrum.TRIBUNAL_ADDRESS();
        TribunalMock arbitrumTribunalMock = new TribunalMock();
        vm.etch(TRIBUNAL_ADDRESS, address(arbitrumTribunalMock).code);
        tribunalMockArbitrum = TribunalMock(TRIBUNAL_ADDRESS);

        // get quote cost (throwaway gas price for now)
        (quote, quoteCost) = craftSignedQuote(CHAIN_ID_BASE, GAS_LIMIT);

        selectFork(CHAIN_ID_BASE);

        // deploy wormhole arbiter + etch tribunal with TribunalMock
        wormholeArbiterBase = new WormholeArbiter{salt: salt}();
        TribunalMock baseTribunalMock = new TribunalMock();
        vm.etch(TRIBUNAL_ADDRESS, address(baseTribunalMock).code);
        tribunalMockBase = TribunalMock(TRIBUNAL_ADDRESS);

        // deploy the compact mock
        MockTheCompact deployedCompactMock = new MockTheCompact();
        bytes memory compactCode = address(deployedCompactMock).code;
        vm.etch(THE_COMPACT_ADDRESS, compactCode);
        compactMock = MockTheCompact(THE_COMPACT_ADDRESS);
    }

    function test_deployments_success() public {
        // Tribunals deployed to same address on both forks
        assertEq(address(tribunalMockArbitrum), address(tribunalMockBase));
        assertTrue(address(tribunalMockArbitrum) != address(0));

        // Arbiters deployed to same address on both forks
        assertEq(address(wormholeArbiterArbitrum), address(wormholeArbiterBase));
        assertTrue(address(wormholeArbiterArbitrum) != address(0));

        // Compact mock etched to correct address
        assertEq(address(compactMock), THE_COMPACT_ADDRESS);

        // check that the filler has 5 eth
        selectFork(CHAIN_ID_ARBITRUM);
        assertEq(address(filler).balance, 5 ether);
    }

    // TODO: check WormholeExecutor.sol cases too
    // TODO: check for expected calls emits on the lower level contracts
    // TODO: make sure publish and relay sets peer address to the arbiter address
    function test_send_single_send() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei); // for this test, message fees will be 0, will be tested later

        // create single lock + get claim hash + set in mock tribunal
        Lock[] memory locks = createLocks(1);
        bytes32 claimHash = wormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        tribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        // filler sends the claim (TODO: check for expected emits)
        vm.prank(filler);
        vm.recordLogs();
        wormholeArbiterArbitrum.send{
            value: quoteCost
        }(
            BASE_CHAIN_ID_STANDARD,
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            WormholeParams({totalCost: quoteCost, gasLimit: GAS_LIMIT}),
            quote
        );

        //check that the filler has quote amount less eth on arbitrum
        assertEq(address(filler).balance, 5 ether - uint256(quoteCost));

        // Switch to base and verify claim hash is not set yet
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash));

        // Set expectation for 1 call to arbiter
        vm.expectCall(address(wormholeArbiterBase), abi.encodeWithSignature("executeVAAv1(bytes)"), 1);

        // Switch back to arbitrum to execute the relay
        selectFork(CHAIN_ID_ARBITRUM);
        executeRelay();

        //check that the claim hash is set as marked on the mock compact
        selectFork(CHAIN_ID_BASE);
        assertTrue(compactMock.getClaimHash(claimHash));

        // check that the received claim matches the input data
        BatchClaim memory receivedClaim = compactMock.getReceivedClaim(claimHash);
        assertClaimEquality(
            receivedClaim,
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            locks,
            CLAIMANT,
            1e18 // normative scaling factor
        );
    }

    function test_send_single_send_dispatch_callback() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei); // for this test, message fees will be 0, will be tested later

        // create single lock + batch compact + get claim hash + set in mock tribunal
        Lock[] memory locks = createLocks(1);
        BatchCompact memory compact = BatchCompact({
            arbiter: address(wormholeArbiterArbitrum),
            sponsor: SPONSOR,
            nonce: NONCE,
            expires: EXPIRES,
            commitments: locks
        });
        bytes32 claimHash = wormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        tribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        //encode send context
        bytes memory context = wormholeArbiterArbitrum.encodeSendContext(
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            WormholeParams({totalCost: quoteCost, gasLimit: GAS_LIMIT}),
            quote,
            filler
        );

        // filler sends the claim (TODO: check for expected emits)
        vm.prank(filler);
        vm.recordLogs();
        tribunalMockArbitrum.dispatchCallback{
            value: quoteCost
        }(BASE_CHAIN_ID_STANDARD, compact, WITNESS, claimHash, CLAIMANT, 1e18, new uint256[](0), context);

        // check that the filler has quote amount less eth on arbitrum
        assertEq(address(filler).balance, 5 ether - uint256(quoteCost));

        // Switch to base and verify claim hash is not set yet
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash));

        // Set expectation for 1 call to arbiter
        vm.expectCall(address(wormholeArbiterBase), abi.encodeWithSignature("executeVAAv1(bytes)"), 1);

        // Switch back to arbitrum to execute the relay
        selectFork(CHAIN_ID_ARBITRUM);
        executeRelay();

        // check that the claim hash is set as marked in the mock compact
        selectFork(CHAIN_ID_BASE);
        assertTrue(compactMock.getClaimHash(claimHash));

        // check that the received claim matches the input data
        BatchClaim memory receivedClaim = compactMock.getReceivedClaim(claimHash);
        assertClaimEquality(
            receivedClaim,
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            locks,
            CLAIMANT,
            1e18 // normative scaling factor
        );
    }

    function test_send_batch_send() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        // create locks for both claims
        Lock[] memory locks1 = createLocks(1);
        Lock[] memory locks2 = createLocks(3);

        // claim 1 params
        address sponsor1 = SPONSOR;
        uint256 nonce1 = NONCE;
        uint256 expires1 = EXPIRES;
        bytes32 witness1 = WITNESS;
        bytes32 claimant1 = CLAIMANT;
        bytes memory allocatorData1 = bytes("");
        bytes memory sponsorSignature1 = bytes("");

        // claim 2 params (all different)
        address sponsor2 = address(uint160(SPONSOR) + 1);
        uint256 nonce2 = NONCE + 1;
        uint256 expires2 = EXPIRES + 1;
        bytes32 witness2 = keccak256("witness2");
        bytes32 claimant2 = bytes32(uint256(CLAIMANT) + 1);
        bytes memory allocatorData2 = abi.encodePacked(keccak256("allocator_data_2"));
        bytes memory sponsorSignature2 = abi.encodePacked(keccak256("sponsor_signature_2"));

        // derive claim hashes + set in mock tribunal
        bytes32 claimHash1 = wormholeArbiterArbitrum.deriveClaimHash(sponsor1, nonce1, expires1, witness1, locks1);
        tribunalMockArbitrum.setFilled(claimHash1, claimant1);
        bytes32 claimHash2 = wormholeArbiterArbitrum.deriveClaimHash(sponsor2, nonce2, expires2, witness2, locks2);
        tribunalMockArbitrum.setFilled(claimHash2, claimant2);

        // construct BatchClaimWithLocks array
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](2);
        claims[0] = BatchClaimWithLocks({
            sponsor: sponsor1,
            nonce: nonce1,
            expires: expires1,
            witness: witness1,
            allocatorData: allocatorData1,
            sponsorSignature: sponsorSignature1,
            commitments: locks1
        });
        claims[1] = BatchClaimWithLocks({
            sponsor: sponsor2,
            nonce: nonce2,
            expires: expires2,
            witness: witness2,
            allocatorData: allocatorData2,
            sponsorSignature: sponsorSignature2,
            commitments: locks2
        });

        // construct and send batch
        BatchSend memory batch = BatchSend({
            chainId: BASE_CHAIN_ID_STANDARD,
            claims: claims,
            gasLimit: GAS_LIMIT,
            totalCost: quoteCost,
            signedQuote: quote
        });
        vm.prank(filler);
        vm.recordLogs();
        wormholeArbiterArbitrum.batchSend{value: quoteCost}(batch);

        // check filler balance
        assertEq(address(filler).balance, 5 ether - uint256(quoteCost));

        // verify claim hashes not set yet on base
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash1));
        assertFalse(compactMock.getClaimHash(claimHash2));

        // execute relay
        vm.expectCall(address(wormholeArbiterBase), abi.encodeWithSignature("executeVAAv1(bytes)"), 1);
        selectFork(CHAIN_ID_ARBITRUM);
        executeRelay();

        // check claim hashes are set on base
        selectFork(CHAIN_ID_BASE);
        assertTrue(compactMock.getClaimHash(claimHash1));
        assertTrue(compactMock.getClaimHash(claimHash2));

        // check received claims match input data
        BatchClaim memory receivedClaim1 = compactMock.getReceivedClaim(claimHash1);
        assertClaimEquality(
            receivedClaim1,
            sponsor1,
            nonce1,
            expires1,
            witness1,
            allocatorData1,
            sponsorSignature1,
            locks1,
            claimant1,
            1e18
        );
        BatchClaim memory receivedClaim2 = compactMock.getReceivedClaim(claimHash2);
        assertClaimEquality(
            receivedClaim2,
            sponsor2,
            nonce2,
            expires2,
            witness2,
            allocatorData2,
            sponsorSignature2,
            locks2,
            claimant2,
            1e18
        );
    }

    function test_send_multichain_batch_send() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        // create all data using arrays to reduce stack depth
        Lock[][] memory allLocks = new Lock[][](4);
        BatchClaimWithLocks[] memory allClaims = new BatchClaimWithLocks[](4);
        bytes32[] memory claimHashes = new bytes32[](4);
        bytes32[] memory claimants = new bytes32[](4);

        for (uint256 i = 0; i < 4; i++) {
            allLocks[i] = createLocks(i + 1);
            allClaims[i] = createBatchClaimWithLocks(i, allLocks[i]);
            claimHashes[i] = wormholeArbiterArbitrum.deriveClaimHash(
                allClaims[i].sponsor, allClaims[i].nonce, allClaims[i].expires, allClaims[i].witness, allLocks[i]
            );
            claimants[i] = bytes32(uint256(CLAIMANT) + i);
            tribunalMockArbitrum.setFilled(claimHashes[i], claimants[i]);
        }

        // construct batches (2 claims each)
        BatchClaimWithLocks[] memory batchClaims1 = new BatchClaimWithLocks[](2);
        batchClaims1[0] = allClaims[0];
        batchClaims1[1] = allClaims[1];

        BatchClaimWithLocks[] memory batchClaims2 = new BatchClaimWithLocks[](2);
        batchClaims2[0] = allClaims[2];
        batchClaims2[1] = allClaims[3];

        // construct and send multichain batch (both targeting BASE)
        BatchSend[] memory batches = new BatchSend[](2);
        batches[0] = BatchSend({
            chainId: BASE_CHAIN_ID_STANDARD,
            claims: batchClaims1,
            gasLimit: GAS_LIMIT,
            totalCost: quoteCost,
            signedQuote: quote
        });
        batches[1] = BatchSend({
            chainId: BASE_CHAIN_ID_STANDARD,
            claims: batchClaims2,
            gasLimit: GAS_LIMIT,
            totalCost: quoteCost,
            signedQuote: quote
        });
        vm.prank(filler);
        vm.recordLogs();
        wormholeArbiterArbitrum.multichainBatchSend{value: quoteCost * 2}(batches);

        // check filler balance (2x quote cost)
        assertEq(address(filler).balance, 5 ether - uint256(quoteCost * 2));

        // verify claim hashes not set yet on base
        selectFork(CHAIN_ID_BASE);
        for (uint256 i = 0; i < 4; i++) {
            assertFalse(compactMock.getClaimHash(claimHashes[i]));
        }

        // execute relay (2 calls to arbiter, one per batch)
        uint256 initialCallCount = compactMock.getCallCount();
        vm.expectCall(address(wormholeArbiterBase), abi.encodeWithSignature("executeVAAv1(bytes)"), 2);
        selectFork(CHAIN_ID_ARBITRUM);
        executeRelay();

        // check all 4 claim hashes are set on base + verify claim equality
        selectFork(CHAIN_ID_BASE);
        for (uint256 i = 0; i < 4; i++) {
            assertTrue(compactMock.getClaimHash(claimHashes[i]));
            checkClaimEquality(claimHashes[i], allClaims[i], allLocks[i], claimants[i], 1e18);
        }

        // verify call count increased by 4 (2 claims per batch, 2 batches)
        assertEq(compactMock.getCallCount(), initialCallCount + 4);
    }

    // test that messages go through with non-zero wormhole message fee
    function test_send_single_send_fees() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(10 gwei);
        uint256 totalCost = quoteCost + 10 gwei;

        // create single lock + get claim hash + set in mock tribunal
        Lock[] memory locks = createLocks(1);
        bytes32 claimHash = wormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        tribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        // filler sends the claim
        vm.prank(filler);
        vm.recordLogs();
        wormholeArbiterArbitrum.send{
            value: totalCost
        }(
            BASE_CHAIN_ID_STANDARD,
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            WormholeParams({totalCost: totalCost, gasLimit: GAS_LIMIT}),
            quote
        );

        // check filler balance decremented by total cost (quote + message fee)
        assertEq(address(filler).balance, 5 ether - totalCost);

        // verify claim hash not set yet on base
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash));

        // execute relay
        selectFork(CHAIN_ID_ARBITRUM);
        executeRelay();

        // verify claim hash is set on base
        selectFork(CHAIN_ID_BASE);
        assertTrue(compactMock.getClaimHash(claimHash));

        // check claim equality
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

    function test_send_dispatch_callback_fees() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(10 gwei);
        uint256 totalCost = quoteCost + 10 gwei;

        // create single lock + batch compact + get claim hash + set in mock tribunal
        Lock[] memory locks = createLocks(1);
        BatchCompact memory compact = BatchCompact({
            arbiter: address(wormholeArbiterArbitrum),
            sponsor: SPONSOR,
            nonce: NONCE,
            expires: EXPIRES,
            commitments: locks
        });
        bytes32 claimHash = wormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        tribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        // encode send context with total cost including message fee
        bytes memory context = wormholeArbiterArbitrum.encodeSendContext(
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            WormholeParams({totalCost: totalCost, gasLimit: GAS_LIMIT}),
            quote,
            filler
        );

        // filler sends the claim via tribunal
        vm.prank(filler);
        vm.recordLogs();
        tribunalMockArbitrum.dispatchCallback{
            value: totalCost
        }(BASE_CHAIN_ID_STANDARD, compact, WITNESS, claimHash, CLAIMANT, 1e18, new uint256[](0), context);

        // check filler balance decremented by total cost (quote + message fee)
        assertEq(address(filler).balance, 5 ether - totalCost);

        // verify claim hash not set yet on base
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash));

        // execute relay
        selectFork(CHAIN_ID_ARBITRUM);
        executeRelay();

        // verify claim hash is set on base
        selectFork(CHAIN_ID_BASE);
        assertTrue(compactMock.getClaimHash(claimHash));

        // check claim equality
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

    function test_send_batch_send_fees() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(10 gwei);
        uint256 totalCost = quoteCost + 10 gwei;

        // create locks and claims using helpers
        Lock[] memory locks1 = createLocks(1);
        Lock[] memory locks2 = createLocks(2);
        BatchClaimWithLocks memory claim1 = createBatchClaimWithLocks(0, locks1);
        BatchClaimWithLocks memory claim2 = createBatchClaimWithLocks(1, locks2);

        // derive claim hashes + set in mock tribunal
        bytes32 claimHash1 = wormholeArbiterArbitrum.deriveClaimHash(
            claim1.sponsor, claim1.nonce, claim1.expires, claim1.witness, locks1
        );
        bytes32 claimHash2 = wormholeArbiterArbitrum.deriveClaimHash(
            claim2.sponsor, claim2.nonce, claim2.expires, claim2.witness, locks2
        );
        tribunalMockArbitrum.setFilled(claimHash1, CLAIMANT);
        tribunalMockArbitrum.setFilled(claimHash2, bytes32(uint256(CLAIMANT) + 1));

        // construct and send batch
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](2);
        claims[0] = claim1;
        claims[1] = claim2;

        BatchSend memory batch = BatchSend({
            chainId: BASE_CHAIN_ID_STANDARD,
            claims: claims,
            gasLimit: GAS_LIMIT,
            totalCost: totalCost,
            signedQuote: quote
        });
        vm.prank(filler);
        vm.recordLogs();
        wormholeArbiterArbitrum.batchSend{value: totalCost}(batch);

        // check filler balance decremented by total cost (quote + message fee)
        assertEq(address(filler).balance, 5 ether - totalCost);

        // verify claim hashes not set yet on base
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash1));
        assertFalse(compactMock.getClaimHash(claimHash2));

        // execute relay
        selectFork(CHAIN_ID_ARBITRUM);
        executeRelay();

        // verify claim hashes are set on base
        selectFork(CHAIN_ID_BASE);
        assertTrue(compactMock.getClaimHash(claimHash1));
        assertTrue(compactMock.getClaimHash(claimHash2));

        // check claim equality
        checkClaimEquality(claimHash1, claim1, locks1, CLAIMANT, 1e18);
        checkClaimEquality(claimHash2, claim2, locks2, bytes32(uint256(CLAIMANT) + 1), 1e18);
    }

    function test_send_multichain_batch_send_fees() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(10 gwei);
        uint256 totalCostPerBatch = quoteCost + 10 gwei;

        // create all data using arrays to reduce stack depth
        Lock[][] memory allLocks = new Lock[][](4);
        BatchClaimWithLocks[] memory allClaims = new BatchClaimWithLocks[](4);
        bytes32[] memory claimHashes = new bytes32[](4);

        for (uint256 i = 0; i < 4; i++) {
            allLocks[i] = createLocks(i + 1);
            allClaims[i] = createBatchClaimWithLocks(i, allLocks[i]);
            claimHashes[i] = wormholeArbiterArbitrum.deriveClaimHash(
                allClaims[i].sponsor, allClaims[i].nonce, allClaims[i].expires, allClaims[i].witness, allLocks[i]
            );
            tribunalMockArbitrum.setFilled(claimHashes[i], bytes32(uint256(CLAIMANT) + i));
        }

        // construct batches (2 claims each)
        BatchClaimWithLocks[] memory batchClaims1 = new BatchClaimWithLocks[](2);
        batchClaims1[0] = allClaims[0];
        batchClaims1[1] = allClaims[1];

        BatchClaimWithLocks[] memory batchClaims2 = new BatchClaimWithLocks[](2);
        batchClaims2[0] = allClaims[2];
        batchClaims2[1] = allClaims[3];

        // construct and send multichain batch (both targeting BASE)
        BatchSend[] memory batches = new BatchSend[](2);
        batches[0] = BatchSend({
            chainId: BASE_CHAIN_ID_STANDARD,
            claims: batchClaims1,
            gasLimit: GAS_LIMIT,
            totalCost: totalCostPerBatch,
            signedQuote: quote
        });
        batches[1] = BatchSend({
            chainId: BASE_CHAIN_ID_STANDARD,
            claims: batchClaims2,
            gasLimit: GAS_LIMIT,
            totalCost: totalCostPerBatch,
            signedQuote: quote
        });
        vm.prank(filler);
        vm.recordLogs();
        wormholeArbiterArbitrum.multichainBatchSend{value: totalCostPerBatch * 2}(batches);

        // check filler balance decremented by total cost (2 batches × (quote + message fee))
        assertEq(address(filler).balance, 5 ether - (totalCostPerBatch * 2));

        // verify claim hashes not set yet on base
        selectFork(CHAIN_ID_BASE);
        for (uint256 i = 0; i < 4; i++) {
            assertFalse(compactMock.getClaimHash(claimHashes[i]));
        }

        // execute relay
        selectFork(CHAIN_ID_ARBITRUM);
        executeRelay();

        // verify claim hashes are set on base + check claim equality
        selectFork(CHAIN_ID_BASE);
        for (uint256 i = 0; i < 4; i++) {
            assertTrue(compactMock.getClaimHash(claimHashes[i]));
            checkClaimEquality(claimHashes[i], allClaims[i], allLocks[i], bytes32(uint256(CLAIMANT) + i), 1e18);
        }
    }

    // test for non-normative scaling factor (e.g. 0.5e18)
    function test_send_single_send_scaling_factor() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);
        uint256 scalingFactor = 0.5e18;

        // create single lock + get claim hash + set in mock tribunal with scaling factor
        Lock[] memory locks = createLocks(1);
        bytes32 claimHash = wormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        tribunalMockArbitrum.setFilled(claimHash, CLAIMANT);
        tribunalMockArbitrum.setClaimReductionScalingFactor(claimHash, scalingFactor);

        // filler sends the claim
        vm.prank(filler);
        vm.recordLogs();
        wormholeArbiterArbitrum.send{
            value: quoteCost
        }(
            BASE_CHAIN_ID_STANDARD,
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            WormholeParams({totalCost: quoteCost, gasLimit: GAS_LIMIT}),
            quote
        );

        // verify claim hash not set yet on base
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash));

        // execute relay
        selectFork(CHAIN_ID_ARBITRUM);
        executeRelay();

        // verify claim hash is set on base
        selectFork(CHAIN_ID_BASE);
        assertTrue(compactMock.getClaimHash(claimHash));

        // check claim equality with scaling factor
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
            scalingFactor
        );
    }

    function test_dispatch_callback_scaling_factor() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);
        uint256 scalingFactor = 0.5e18;

        // create single lock + batch compact + get claim hash + set in mock tribunal
        Lock[] memory locks = createLocks(1);
        BatchCompact memory compact = BatchCompact({
            arbiter: address(wormholeArbiterArbitrum),
            sponsor: SPONSOR,
            nonce: NONCE,
            expires: EXPIRES,
            commitments: locks
        });
        bytes32 claimHash = wormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        tribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        // encode send context
        bytes memory context = wormholeArbiterArbitrum.encodeSendContext(
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            WormholeParams({totalCost: quoteCost, gasLimit: GAS_LIMIT}),
            quote,
            filler
        );

        // filler sends the claim via tribunal with scaling factor
        vm.prank(filler);
        vm.recordLogs();
        tribunalMockArbitrum.dispatchCallback{
            value: quoteCost
        }(BASE_CHAIN_ID_STANDARD, compact, WITNESS, claimHash, CLAIMANT, scalingFactor, new uint256[](0), context);

        // verify claim hash not set yet on base
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash));

        // execute relay
        selectFork(CHAIN_ID_ARBITRUM);
        executeRelay();

        // verify claim hash is set on base
        selectFork(CHAIN_ID_BASE);
        assertTrue(compactMock.getClaimHash(claimHash));

        // check claim equality with scaling factor
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
            scalingFactor
        );
    }

    function test_send_batch_send_scaling_factor() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);
        uint256 scalingFactor1 = 0.5e18;
        uint256 scalingFactor2 = 0.75e18;

        // create locks and claims using helpers
        Lock[] memory locks1 = createLocks(1);
        Lock[] memory locks2 = createLocks(2);
        BatchClaimWithLocks memory claim1 = createBatchClaimWithLocks(0, locks1);
        BatchClaimWithLocks memory claim2 = createBatchClaimWithLocks(1, locks2);

        // derive claim hashes + set in mock tribunal with different scaling factors
        bytes32 claimHash1 = wormholeArbiterArbitrum.deriveClaimHash(
            claim1.sponsor, claim1.nonce, claim1.expires, claim1.witness, locks1
        );
        bytes32 claimHash2 = wormholeArbiterArbitrum.deriveClaimHash(
            claim2.sponsor, claim2.nonce, claim2.expires, claim2.witness, locks2
        );
        tribunalMockArbitrum.setFilled(claimHash1, CLAIMANT);
        tribunalMockArbitrum.setFilled(claimHash2, bytes32(uint256(CLAIMANT) + 1));
        tribunalMockArbitrum.setClaimReductionScalingFactor(claimHash1, scalingFactor1);
        tribunalMockArbitrum.setClaimReductionScalingFactor(claimHash2, scalingFactor2);

        // construct and send batch
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](2);
        claims[0] = claim1;
        claims[1] = claim2;

        BatchSend memory batch = BatchSend({
            chainId: BASE_CHAIN_ID_STANDARD,
            claims: claims,
            gasLimit: GAS_LIMIT,
            totalCost: quoteCost,
            signedQuote: quote
        });
        vm.prank(filler);
        vm.recordLogs();
        wormholeArbiterArbitrum.batchSend{value: quoteCost}(batch);

        // verify claim hashes not set yet on base
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash1));
        assertFalse(compactMock.getClaimHash(claimHash2));

        // execute relay
        selectFork(CHAIN_ID_ARBITRUM);
        executeRelay();

        // verify claim hashes are set on base
        selectFork(CHAIN_ID_BASE);
        assertTrue(compactMock.getClaimHash(claimHash1));
        assertTrue(compactMock.getClaimHash(claimHash2));

        // check claim equality with different scaling factors
        checkClaimEquality(claimHash1, claim1, locks1, CLAIMANT, scalingFactor1);
        checkClaimEquality(claimHash2, claim2, locks2, bytes32(uint256(CLAIMANT) + 1), scalingFactor2);
    }

    function test_send_multichain_batch_send_scaling_factor() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        // different scaling factors for each claim
        uint256[] memory scalingFactors = new uint256[](4);
        scalingFactors[0] = 0.25e18;
        scalingFactors[1] = 0.5e18;
        scalingFactors[2] = 0.75e18;
        scalingFactors[3] = 0.9e18;

        // create all data using arrays to reduce stack depth
        Lock[][] memory allLocks = new Lock[][](4);
        BatchClaimWithLocks[] memory allClaims = new BatchClaimWithLocks[](4);
        bytes32[] memory claimHashes = new bytes32[](4);

        for (uint256 i = 0; i < 4; i++) {
            allLocks[i] = createLocks(i + 1);
            allClaims[i] = createBatchClaimWithLocks(i, allLocks[i]);
            claimHashes[i] = wormholeArbiterArbitrum.deriveClaimHash(
                allClaims[i].sponsor, allClaims[i].nonce, allClaims[i].expires, allClaims[i].witness, allLocks[i]
            );
            tribunalMockArbitrum.setFilled(claimHashes[i], bytes32(uint256(CLAIMANT) + i));
            tribunalMockArbitrum.setClaimReductionScalingFactor(claimHashes[i], scalingFactors[i]);
        }

        // construct batches (2 claims each)
        BatchClaimWithLocks[] memory batchClaims1 = new BatchClaimWithLocks[](2);
        batchClaims1[0] = allClaims[0];
        batchClaims1[1] = allClaims[1];

        BatchClaimWithLocks[] memory batchClaims2 = new BatchClaimWithLocks[](2);
        batchClaims2[0] = allClaims[2];
        batchClaims2[1] = allClaims[3];

        // construct and send multichain batch (both targeting BASE)
        BatchSend[] memory batches = new BatchSend[](2);
        batches[0] = BatchSend({
            chainId: BASE_CHAIN_ID_STANDARD,
            claims: batchClaims1,
            gasLimit: GAS_LIMIT,
            totalCost: quoteCost,
            signedQuote: quote
        });
        batches[1] = BatchSend({
            chainId: BASE_CHAIN_ID_STANDARD,
            claims: batchClaims2,
            gasLimit: GAS_LIMIT,
            totalCost: quoteCost,
            signedQuote: quote
        });
        vm.prank(filler);
        vm.recordLogs();
        wormholeArbiterArbitrum.multichainBatchSend{value: quoteCost * 2}(batches);

        // verify claim hashes not set yet on base
        selectFork(CHAIN_ID_BASE);
        for (uint256 i = 0; i < 4; i++) {
            assertFalse(compactMock.getClaimHash(claimHashes[i]));
        }

        // execute relay
        selectFork(CHAIN_ID_ARBITRUM);
        executeRelay();

        // verify claim hashes are set on base + check claim equality with scaling factors
        selectFork(CHAIN_ID_BASE);
        for (uint256 i = 0; i < 4; i++) {
            assertTrue(compactMock.getClaimHash(claimHashes[i]));
            checkClaimEquality(
                claimHashes[i], allClaims[i], allLocks[i], bytes32(uint256(CLAIMANT) + i), scalingFactors[i]
            );
        }
    }

    // test for 0 scaling factor (cancelled claims - empty portions)
    function test_send_single_send_0_scaling_factor() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);
        uint256 scalingFactor = 0;

        // create single lock + get claim hash + set in mock tribunal with 0 scaling factor
        Lock[] memory locks = createLocks(1);
        bytes32 claimHash = wormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        tribunalMockArbitrum.setFilled(claimHash, CLAIMANT);
        tribunalMockArbitrum.setClaimReductionScalingFactor(claimHash, type(uint256).max); // max = cancelled = returns 0

        // filler sends the claim
        vm.prank(filler);
        vm.recordLogs();
        wormholeArbiterArbitrum.send{
            value: quoteCost
        }(
            BASE_CHAIN_ID_STANDARD,
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            WormholeParams({totalCost: quoteCost, gasLimit: GAS_LIMIT}),
            quote
        );

        // execute relay
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash));
        selectFork(CHAIN_ID_ARBITRUM);
        executeRelay();

        // verify claim hash is set on base with empty portions (cancelled)
        selectFork(CHAIN_ID_BASE);
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
            scalingFactor
        );
    }

    function test_dispatch_callback_0_scaling_factor() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);
        uint256 scalingFactor = 0;

        // create single lock + batch compact + get claim hash + set in mock tribunal
        Lock[] memory locks = createLocks(1);
        BatchCompact memory compact = BatchCompact({
            arbiter: address(wormholeArbiterArbitrum),
            sponsor: SPONSOR,
            nonce: NONCE,
            expires: EXPIRES,
            commitments: locks
        });
        bytes32 claimHash = wormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        tribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        // encode send context
        bytes memory context = wormholeArbiterArbitrum.encodeSendContext(
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            WormholeParams({totalCost: quoteCost, gasLimit: GAS_LIMIT}),
            quote,
            filler
        );

        // filler sends the claim via tribunal with 0 scaling factor (cancelled)
        vm.prank(filler);
        vm.recordLogs();
        tribunalMockArbitrum.dispatchCallback{
            value: quoteCost
        }(BASE_CHAIN_ID_STANDARD, compact, WITNESS, claimHash, CLAIMANT, scalingFactor, new uint256[](0), context);

        // execute relay
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash));
        selectFork(CHAIN_ID_ARBITRUM);
        executeRelay();

        // verify claim hash is set on base with empty portions (cancelled)
        selectFork(CHAIN_ID_BASE);
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
            scalingFactor
        );
    }

    function test_send_batch_send_0_scaling_factor() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);
        uint256 scalingFactor = 0;

        // create locks and claims using helpers
        Lock[] memory locks1 = createLocks(1);
        Lock[] memory locks2 = createLocks(2);
        BatchClaimWithLocks memory claim1 = createBatchClaimWithLocks(0, locks1);
        BatchClaimWithLocks memory claim2 = createBatchClaimWithLocks(1, locks2);

        // derive claim hashes + set in mock tribunal with 0 scaling factor (cancelled)
        bytes32 claimHash1 = wormholeArbiterArbitrum.deriveClaimHash(
            claim1.sponsor, claim1.nonce, claim1.expires, claim1.witness, locks1
        );
        bytes32 claimHash2 = wormholeArbiterArbitrum.deriveClaimHash(
            claim2.sponsor, claim2.nonce, claim2.expires, claim2.witness, locks2
        );
        tribunalMockArbitrum.setFilled(claimHash1, CLAIMANT);
        tribunalMockArbitrum.setFilled(claimHash2, bytes32(uint256(CLAIMANT) + 1));
        tribunalMockArbitrum.setClaimReductionScalingFactor(claimHash1, type(uint256).max);
        tribunalMockArbitrum.setClaimReductionScalingFactor(claimHash2, type(uint256).max);

        // construct and send batch
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](2);
        claims[0] = claim1;
        claims[1] = claim2;

        BatchSend memory batch = BatchSend({
            chainId: BASE_CHAIN_ID_STANDARD,
            claims: claims,
            gasLimit: GAS_LIMIT,
            totalCost: quoteCost,
            signedQuote: quote
        });
        vm.prank(filler);
        vm.recordLogs();
        wormholeArbiterArbitrum.batchSend{value: quoteCost}(batch);

        // execute relay
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash1));
        assertFalse(compactMock.getClaimHash(claimHash2));
        selectFork(CHAIN_ID_ARBITRUM);
        executeRelay();

        // verify claim hashes are set on base with empty portions (cancelled)
        selectFork(CHAIN_ID_BASE);
        assertTrue(compactMock.getClaimHash(claimHash1));
        assertTrue(compactMock.getClaimHash(claimHash2));
        checkClaimEquality(claimHash1, claim1, locks1, CLAIMANT, scalingFactor);
        checkClaimEquality(claimHash2, claim2, locks2, bytes32(uint256(CLAIMANT) + 1), scalingFactor);
    }

    function test_send_multichain_batch_send_0_scaling_factor() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);
        uint256 scalingFactor = 0;

        // create all data using arrays to reduce stack depth
        Lock[][] memory allLocks = new Lock[][](4);
        BatchClaimWithLocks[] memory allClaims = new BatchClaimWithLocks[](4);
        bytes32[] memory claimHashes = new bytes32[](4);

        for (uint256 i = 0; i < 4; i++) {
            allLocks[i] = createLocks(i + 1);
            allClaims[i] = createBatchClaimWithLocks(i, allLocks[i]);
            claimHashes[i] = wormholeArbiterArbitrum.deriveClaimHash(
                allClaims[i].sponsor, allClaims[i].nonce, allClaims[i].expires, allClaims[i].witness, allLocks[i]
            );
            tribunalMockArbitrum.setFilled(claimHashes[i], bytes32(uint256(CLAIMANT) + i));
            tribunalMockArbitrum.setClaimReductionScalingFactor(claimHashes[i], type(uint256).max);
        }

        // construct batches (2 claims each)
        BatchClaimWithLocks[] memory batchClaims1 = new BatchClaimWithLocks[](2);
        batchClaims1[0] = allClaims[0];
        batchClaims1[1] = allClaims[1];

        BatchClaimWithLocks[] memory batchClaims2 = new BatchClaimWithLocks[](2);
        batchClaims2[0] = allClaims[2];
        batchClaims2[1] = allClaims[3];

        // construct and send multichain batch (both targeting BASE)
        BatchSend[] memory batches = new BatchSend[](2);
        batches[0] = BatchSend({
            chainId: BASE_CHAIN_ID_STANDARD,
            claims: batchClaims1,
            gasLimit: GAS_LIMIT,
            totalCost: quoteCost,
            signedQuote: quote
        });
        batches[1] = BatchSend({
            chainId: BASE_CHAIN_ID_STANDARD,
            claims: batchClaims2,
            gasLimit: GAS_LIMIT,
            totalCost: quoteCost,
            signedQuote: quote
        });
        vm.prank(filler);
        vm.recordLogs();
        wormholeArbiterArbitrum.multichainBatchSend{value: quoteCost * 2}(batches);

        // execute relay
        selectFork(CHAIN_ID_BASE);
        for (uint256 i = 0; i < 4; i++) {
            assertFalse(compactMock.getClaimHash(claimHashes[i]));
        }
        selectFork(CHAIN_ID_ARBITRUM);
        executeRelay();

        // verify claim hashes are set on base with empty portions (cancelled)
        selectFork(CHAIN_ID_BASE);
        for (uint256 i = 0; i < 4; i++) {
            assertTrue(compactMock.getClaimHash(claimHashes[i]));
            checkClaimEquality(claimHashes[i], allClaims[i], allLocks[i], bytes32(uint256(CLAIMANT) + i), scalingFactor);
        }
    }

    ///// send test edge cases / low level cases trib side /////

    // check to make sure the core bridge publishMessage is called with the correct arguments
    function test_send_publish_message_and_request_execution_correct_arguments() public {
        selectFork(CHAIN_ID_ARBITRUM);
        uint256 testMessageFee = 0.01 gwei;
        setMessageFee(testMessageFee);

        // Create single lock + get claim hash + set in mock tribunal
        Lock[] memory locks = createLocks(1);
        bytes32 claimHash = wormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        tribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        // Get contract addresses from WormholeMappings
        address coreBridge = WormholeMappings.getWormhole(block.chainid);
        address executor = WormholeMappings.getWormholeExecutor(block.chainid);

        // Pre-compute expected values
        bytes32 peerAddress = bytes32(uint256(uint160(address(wormholeArbiterArbitrum))));
        uint16 wormholeArbitrumChainId = WormholeMappings.toWormholeId(block.chainid); // 23
        uint16 wormholeBaseChainId = WormholeMappings.toWormholeId(BASE_CHAIN_ID_STANDARD); // 30
        uint64 expectedSequence = ICoreBridge(coreBridge).nextSequence(address(wormholeArbiterArbitrum));

        // Expected payload from Message.encode
        bytes memory expectedPayload = this.encodeMessageHelper(
            SPONSOR, NONCE, EXPIRES, WITNESS, locks, ALLOCATOR_DATA, SPONSOR_SIGNATURE, CLAIMANT, 1e18
        );

        // Expected relay instructions
        bytes memory expectedRelayInstructions = RelayInstructionLib.encodeGas(GAS_LIMIT, 0);

        // Expected request
        bytes memory expectedRequest =
            RequestLib.encodeVaaMultiSigRequest(wormholeArbitrumChainId, peerAddress, expectedSequence);

        // Set up vm.expectCall for coreBridge.publishMessage
        // Signature: publishMessage(uint32 nonce, bytes memory payload, uint8 consistencyLevel)
        // forge-lint: disable-next-line(mixed-case-variable)
        uint8 CONSISTENCY_LEVEL = 201;
        uint32 expectedNonce = 0; // MessagePackingType.SINGLE_SEND
        vm.expectCall(
            coreBridge,
            testMessageFee,
            abi.encodeCall(ICoreBridge.publishMessage, (expectedNonce, expectedPayload, CONSISTENCY_LEVEL))
        );

        // Set up vm.expectCall for executor.requestExecution
        // Signature: requestExecution(uint16 dstChain, bytes32 dstAddr, address refundAddr, bytes signedQuote, bytes requestBytes, bytes relayInstructions)
        vm.expectCall(
            executor,
            quoteCost - testMessageFee,
            abi.encodeCall(
                IExecutor.requestExecution,
                (wormholeBaseChainId, peerAddress, filler, quote, expectedRequest, expectedRelayInstructions)
            )
        );

        // Execute send as filler
        vm.prank(filler);
        wormholeArbiterArbitrum.send{
            value: quoteCost
        }(
            BASE_CHAIN_ID_STANDARD,
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            WormholeParams({totalCost: quoteCost, gasLimit: GAS_LIMIT}),
            quote
        );
    }

    // check to make sure the core bridge publishMessage is called with the correct arguments for batch send
    function test_batch_send_publish_message_and_request_execution_correct_arguments() public {
        selectFork(CHAIN_ID_ARBITRUM);
        uint256 testMessageFee = 0.01 gwei;
        setMessageFee(testMessageFee);

        // Create 3 claims with varying locks
        uint256 numClaims = 3;
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](numClaims);
        bytes32[] memory claimHashes = new bytes32[](numClaims);
        bytes32[] memory claimants = new bytes32[](numClaims);
        uint256[] memory scalingFactors = new uint256[](numClaims);

        for (uint256 i = 0; i < numClaims; i++) {
            Lock[] memory locks = createLocks(i + 1); // 1, 2, 3 locks respectively
            claims[i] = createBatchClaimWithLocks(i, locks);
            claimHashes[i] = wormholeArbiterArbitrum.deriveClaimHash(
                claims[i].sponsor, claims[i].nonce, claims[i].expires, claims[i].witness, locks
            );
            claimants[i] = bytes32(uint256(CLAIMANT) + i);
            scalingFactors[i] = 1e18; // full claim
            tribunalMockArbitrum.setFilled(claimHashes[i], claimants[i]);
        }

        // Get contract addresses from WormholeMappings
        address coreBridge = WormholeMappings.getWormhole(block.chainid);
        address executor = WormholeMappings.getWormholeExecutor(block.chainid);

        // Pre-compute expected values
        bytes32 peerAddress = bytes32(uint256(uint160(address(wormholeArbiterArbitrum))));
        uint16 wormholeArbitrumChainId = WormholeMappings.toWormholeId(block.chainid); // 23
        uint16 wormholeBaseChainId = WormholeMappings.toWormholeId(BASE_CHAIN_ID_STANDARD); // 30
        uint64 expectedSequence = ICoreBridge(coreBridge).nextSequence(address(wormholeArbiterArbitrum));

        // Expected payload from Message.encodeBatchSend
        bytes memory expectedPayload = this.encodeBatchSendHelper(claimants, scalingFactors, claims);

        // Expected relay instructions
        bytes memory expectedRelayInstructions = RelayInstructionLib.encodeGas(GAS_LIMIT, 0);

        // Expected request
        bytes memory expectedRequest =
            RequestLib.encodeVaaMultiSigRequest(wormholeArbitrumChainId, peerAddress, expectedSequence);

        // Set up vm.expectCall for coreBridge.publishMessage
        // forge-lint: disable-next-line(mixed-case-variable)
        uint8 CONSISTENCY_LEVEL = 201;
        uint32 expectedNonce = 1; // MessagePackingType.BATCH_SEND
        vm.expectCall(
            coreBridge,
            testMessageFee,
            abi.encodeCall(ICoreBridge.publishMessage, (expectedNonce, expectedPayload, CONSISTENCY_LEVEL))
        );

        // Set up vm.expectCall for executor.requestExecution
        vm.expectCall(
            executor,
            quoteCost - testMessageFee,
            abi.encodeCall(
                IExecutor.requestExecution,
                (wormholeBaseChainId, peerAddress, filler, quote, expectedRequest, expectedRelayInstructions)
            )
        );

        // Build the BatchSend struct
        BatchSend memory batch = BatchSend({
            chainId: BASE_CHAIN_ID_STANDARD,
            claims: claims,
            gasLimit: GAS_LIMIT,
            totalCost: quoteCost,
            signedQuote: quote
        });

        // Execute batchSend as filler
        vm.prank(filler);
        wormholeArbiterArbitrum.batchSend{value: quoteCost}(batch);
    }

    // check to make sure requestExecution is called with the correct refundAddress when using dispatchCallback
    // This verifies that the refundAddress from context (not msg.sender/Tribunal) is passed to the executor
    function test_dispatch_callback_request_execution_uses_context_refund_address() public {
        selectFork(CHAIN_ID_ARBITRUM);
        uint256 testMessageFee = 0.01 gwei;
        setMessageFee(testMessageFee);

        address refundRecipient = makeAddr("refundRecipient");

        // Create single lock + batch compact + get claim hash + set in mock tribunal
        Lock[] memory locks = createLocks(1);
        BatchCompact memory compact = BatchCompact({
            arbiter: address(wormholeArbiterArbitrum),
            sponsor: SPONSOR,
            nonce: NONCE,
            expires: EXPIRES,
            commitments: locks
        });
        bytes32 claimHash = wormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        tribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        // Get contract addresses from WormholeMappings
        address coreBridge = WormholeMappings.getWormhole(block.chainid);
        address executor = WormholeMappings.getWormholeExecutor(block.chainid);

        // Pre-compute expected values
        bytes32 peerAddress = bytes32(uint256(uint160(address(wormholeArbiterArbitrum))));
        uint16 wormholeArbitrumChainId = WormholeMappings.toWormholeId(block.chainid); // 23
        uint16 wormholeBaseChainId = WormholeMappings.toWormholeId(BASE_CHAIN_ID_STANDARD); // 30
        uint64 expectedSequence = ICoreBridge(coreBridge).nextSequence(address(wormholeArbiterArbitrum));

        // Expected payload from Message.encode
        bytes memory expectedPayload = this.encodeMessageHelper(
            SPONSOR, NONCE, EXPIRES, WITNESS, locks, ALLOCATOR_DATA, SPONSOR_SIGNATURE, CLAIMANT, 1e18
        );

        // Expected relay instructions
        bytes memory expectedRelayInstructions = RelayInstructionLib.encodeGas(GAS_LIMIT, 0);

        // Expected request
        bytes memory expectedRequest =
            RequestLib.encodeVaaMultiSigRequest(wormholeArbitrumChainId, peerAddress, expectedSequence);

        // Set up vm.expectCall for coreBridge.publishMessage
        // forge-lint: disable-next-line(mixed-case-variable)
        uint8 CONSISTENCY_LEVEL = 201;
        uint32 expectedNonce = 0; // MessagePackingType.SINGLE_SEND
        vm.expectCall(
            coreBridge,
            testMessageFee,
            abi.encodeCall(ICoreBridge.publishMessage, (expectedNonce, expectedPayload, CONSISTENCY_LEVEL))
        );

        // Verify requestExecution is called with refundRecipient (from context), NOT filler/msg.sender
        vm.expectCall(
            executor,
            quoteCost - testMessageFee,
            abi.encodeCall(
                IExecutor.requestExecution,
                (wormholeBaseChainId, peerAddress, refundRecipient, quote, expectedRequest, expectedRelayInstructions)
            )
        );

        // Encode send context with refundRecipient as the refundAddress (different from filler who calls)
        bytes memory context = wormholeArbiterArbitrum.encodeSendContext(
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            WormholeParams({totalCost: quoteCost, gasLimit: GAS_LIMIT}),
            quote,
            refundRecipient
        );

        // Execute via TribunalMock.dispatchCallback (msg.sender to arbiter will be Tribunal, not filler)
        vm.prank(filler);
        tribunalMockArbitrum.dispatchCallback{
            value: quoteCost
        }(BASE_CHAIN_ID_STANDARD, compact, WITNESS, claimHash, CLAIMANT, 1e18, new uint256[](0), context);
    }

    // test for dispatch with invalid arbiter
    function test_send_dispatch_invalid_arbiter() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        Lock[] memory locks = createLocks(1);
        // Set arbiter to a random address instead of wormholeArbiterArbitrum
        BatchCompact memory compact = BatchCompact({
            arbiter: address(0xdead), sponsor: SPONSOR, nonce: NONCE, expires: EXPIRES, commitments: locks
        });
        bytes32 claimHash = wormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        bytes memory context = wormholeArbiterArbitrum.encodeSendContext(
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            WormholeParams({totalCost: quoteCost, gasLimit: GAS_LIMIT}),
            quote,
            filler
        );

        // Call arbiter directly, pranking as TRIBUNAL_ADDRESS to pass UnauthorizedCaller check
        // Should revert with InvalidArbiter because compact.arbiter != address(WormholeArbiter)
        address tribunalAddr = wormholeArbiterArbitrum.TRIBUNAL_ADDRESS();
        vm.deal(tribunalAddr, quoteCost);
        vm.prank(tribunalAddr);
        vm.expectRevert(IWormholeArbiter.InvalidArbiter.selector);
        wormholeArbiterArbitrum.dispatchCallback{
            value: quoteCost
        }(BASE_CHAIN_ID_STANDARD, compact, WITNESS, claimHash, CLAIMANT, 1e18, new uint256[](0), context);
    }

    // test for dispatch with invalid context
    function test_send_dispatch_invalid_context() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        Lock[] memory locks = createLocks(1);
        BatchCompact memory compact = BatchCompact({
            arbiter: address(wormholeArbiterArbitrum),
            sponsor: SPONSOR,
            nonce: NONCE,
            expires: EXPIRES,
            commitments: locks
        });
        bytes32 claimHash = wormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        // Empty context should revert with ContextTooShort
        bytes memory context = "";

        address tribunalAddr = wormholeArbiterArbitrum.TRIBUNAL_ADDRESS();
        vm.deal(tribunalAddr, quoteCost);
        vm.prank(tribunalAddr);
        vm.expectRevert(IWormholeArbiter.ContextTooShort.selector);
        wormholeArbiterArbitrum.dispatchCallback{
            value: quoteCost
        }(BASE_CHAIN_ID_STANDARD, compact, WITNESS, claimHash, CLAIMANT, 1e18, new uint256[](0), context);
    }

    // test for dispatch routing to send or post
    function test_send_dispatch_routing_to_send_or_post() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        // Setup for SEND path
        Lock[] memory locks1 = createLocks(1);
        BatchCompact memory compact1 = BatchCompact({
            arbiter: address(wormholeArbiterArbitrum),
            sponsor: SPONSOR,
            nonce: NONCE,
            expires: EXPIRES,
            commitments: locks1
        });
        bytes32 claimHash1 = wormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks1);
        tribunalMockArbitrum.setFilled(claimHash1, CLAIMANT);

        // SEND context - should emit SingleSendEvent
        bytes memory sendContext = wormholeArbiterArbitrum.encodeSendContext(
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            WormholeParams({totalCost: quoteCost, gasLimit: GAS_LIMIT}),
            quote,
            filler
        );

        vm.expectEmit(true, true, false, false); // check chainId + claimHash, skip sequence
        emit IWormholeArbiter.SingleSendEvent(BASE_CHAIN_ID_STANDARD, claimHash1, 0);

        vm.prank(filler);
        tribunalMockArbitrum.dispatchCallback{
            value: quoteCost
        }(BASE_CHAIN_ID_STANDARD, compact1, WITNESS, claimHash1, CLAIMANT, 1e18, new uint256[](0), sendContext);

        // Setup for POST path - use different nonce to avoid collision
        Lock[] memory locks2 = createLocks(1);
        BatchCompact memory compact2 = BatchCompact({
            arbiter: address(wormholeArbiterArbitrum),
            sponsor: SPONSOR,
            nonce: NONCE + 1,
            expires: EXPIRES,
            commitments: locks2
        });
        bytes32 claimHash2 = wormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE + 1, EXPIRES, WITNESS, locks2);
        tribunalMockArbitrum.setFilled(claimHash2, CLAIMANT);

        // POST context - should emit SinglePostEvent
        bytes memory postContext = wormholeArbiterArbitrum.encodePostContext(ALLOCATOR_DATA, SPONSOR_SIGNATURE);

        // POST only needs message fee (which is 0 in this test)
        vm.expectEmit(true, true, false, false); // check chainId + claimHash, skip sequence
        emit IWormholeArbiter.SinglePostEvent(BASE_CHAIN_ID_STANDARD, claimHash2, 0);

        vm.prank(filler);
        tribunalMockArbitrum.dispatchCallback{
            value: 0
        }(BASE_CHAIN_ID_STANDARD, compact2, WITNESS, claimHash2, CLAIMANT, 1e18, new uint256[](0), postContext);
    }

    // test for dispatch from unauthorized caller (not Tribunal)
    function test_send_dispatch_unauthorized_caller() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        Lock[] memory locks = createLocks(1);
        BatchCompact memory compact = BatchCompact({
            arbiter: address(wormholeArbiterArbitrum),
            sponsor: SPONSOR,
            nonce: NONCE,
            expires: EXPIRES,
            commitments: locks
        });
        bytes32 claimHash = wormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);

        bytes memory context = wormholeArbiterArbitrum.encodeSendContext(
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            WormholeParams({totalCost: quoteCost, gasLimit: GAS_LIMIT}),
            quote,
            filler
        );

        // Call from a random address (not Tribunal) - should revert with UnauthorizedCaller
        vm.prank(filler);
        vm.expectRevert(IWormholeArbiter.UnauthorizedCaller.selector);
        wormholeArbiterArbitrum.dispatchCallback{
            value: quoteCost
        }(BASE_CHAIN_ID_STANDARD, compact, WITNESS, claimHash, CLAIMANT, 1e18, new uint256[](0), context);
    }

    // test for send with invalid claim hash because not filled in tribunal
    function test_send_invalid_claim_hash() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        Lock[] memory locks = createLocks(1);
        // Don't call tribunalMockArbitrum.setFilled() - claim is not filled

        vm.prank(filler);
        vm.expectRevert("Claim not filled in Tribunal");
        wormholeArbiterArbitrum.send{
            value: quoteCost
        }(
            BASE_CHAIN_ID_STANDARD,
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            WormholeParams({totalCost: quoteCost, gasLimit: GAS_LIMIT}),
            quote
        );
    }

    // test for send with invalid message fee for publishing (WormholeExecutor.sol)
    function test_send_invalid_message_fee_publishing() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(10 gwei); // Set non-zero message fee

        Lock[] memory locks = createLocks(1);
        bytes32 claimHash = wormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        tribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        // Send with 0 value - not enough to pay message fee
        vm.prank(filler);
        vm.expectRevert(); // Will revert due to insufficient funds for publishMessage
        wormholeArbiterArbitrum.send{
            value: 0
        }(
            BASE_CHAIN_ID_STANDARD,
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            WormholeParams({totalCost: quoteCost, gasLimit: GAS_LIMIT}),
            quote
        );
    }

    // test for send with invalid fee for execution (WormholeExecutor.sol)
    function test_send_invalid_fee_execution() public {
        selectFork(CHAIN_ID_ARBITRUM);
        uint256 messageFee = 10 gwei;
        setMessageFee(messageFee);

        Lock[] memory locks = createLocks(1);
        bytes32 claimHash = wormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        tribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        // Send only enough for message fee, not enough for executor
        vm.prank(filler);
        vm.expectRevert(); // Will revert due to insufficient funds for requestExecution
        wormholeArbiterArbitrum.send{
            value: messageFee
        }(
            BASE_CHAIN_ID_STANDARD,
            SPONSOR,
            NONCE,
            EXPIRES,
            WITNESS,
            locks,
            ALLOCATOR_DATA,
            SPONSOR_SIGNATURE,
            WormholeParams({totalCost: quoteCost, gasLimit: GAS_LIMIT}),
            quote
        );
    }

    // test for batch send with invalid claim hashes (not filled in tribunal)
    function test_batch_send_invalid_claim_hashes() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        Lock[] memory locks1 = createLocks(1);
        Lock[] memory locks2 = createLocks(2);
        BatchClaimWithLocks memory claim1 = createBatchClaimWithLocks(0, locks1);
        BatchClaimWithLocks memory claim2 = createBatchClaimWithLocks(1, locks2);

        // Only set claim1 as filled, not claim2
        bytes32 claimHash1 = wormholeArbiterArbitrum.deriveClaimHash(
            claim1.sponsor, claim1.nonce, claim1.expires, claim1.witness, locks1
        );
        tribunalMockArbitrum.setFilled(claimHash1, CLAIMANT);
        // claim2 is NOT filled

        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](2);
        claims[0] = claim1;
        claims[1] = claim2;

        BatchSend memory batch = BatchSend({
            chainId: BASE_CHAIN_ID_STANDARD,
            claims: claims,
            gasLimit: GAS_LIMIT,
            totalCost: quoteCost,
            signedQuote: quote
        });

        vm.prank(filler);
        vm.expectRevert("Claim not filled in Tribunal");
        wormholeArbiterArbitrum.batchSend{value: quoteCost}(batch);
    }

    // test for batch send with invalid size (exceeds MAX_MESSAGE_SIZE)
    function test_batch_send_invalid_size() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        // Create many claims to exceed MAX_MESSAGE_SIZE (5000 bytes)
        uint256 numClaims = 20;
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](numClaims);

        for (uint256 i = 0; i < numClaims; i++) {
            Lock[] memory locks = createLocks(3);
            claims[i] = createBatchClaimWithLocks(i, locks);
            bytes32 claimHash = wormholeArbiterArbitrum.deriveClaimHash(
                claims[i].sponsor, claims[i].nonce, claims[i].expires, claims[i].witness, locks
            );
            tribunalMockArbitrum.setFilled(claimHash, bytes32(uint256(CLAIMANT) + i));
        }

        BatchSend memory batch = BatchSend({
            chainId: BASE_CHAIN_ID_STANDARD,
            claims: claims,
            gasLimit: GAS_LIMIT,
            totalCost: quoteCost,
            signedQuote: quote
        });

        vm.prank(filler);
        vm.expectRevert(IWormholeArbiter.MessageExceedsMaxSize.selector);
        wormholeArbiterArbitrum.batchSend{value: quoteCost}(batch);
    }

    // test for multichain batch send with invalid claim hashes (not filled in tribunal)
    function test_multichain_batch_send_invalid_claim_hashes() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei);

        // First batch - filled
        Lock[] memory locks1 = createLocks(1);
        BatchClaimWithLocks memory claim1 = createBatchClaimWithLocks(0, locks1);
        bytes32 claimHash1 = wormholeArbiterArbitrum.deriveClaimHash(
            claim1.sponsor, claim1.nonce, claim1.expires, claim1.witness, locks1
        );
        tribunalMockArbitrum.setFilled(claimHash1, CLAIMANT);

        BatchClaimWithLocks[] memory claims1 = new BatchClaimWithLocks[](1);
        claims1[0] = claim1;

        // Second batch - NOT filled
        Lock[] memory locks2 = createLocks(2);
        BatchClaimWithLocks memory claim2 = createBatchClaimWithLocks(1, locks2);

        BatchClaimWithLocks[] memory claims2 = new BatchClaimWithLocks[](1);
        claims2[0] = claim2;

        BatchSend[] memory batches = new BatchSend[](2);
        batches[0] = BatchSend({
            chainId: BASE_CHAIN_ID_STANDARD,
            claims: claims1,
            gasLimit: GAS_LIMIT,
            totalCost: quoteCost,
            signedQuote: quote
        });
        batches[1] = BatchSend({
            chainId: BASE_CHAIN_ID_STANDARD,
            claims: claims2,
            gasLimit: GAS_LIMIT,
            totalCost: quoteCost,
            signedQuote: quote
        });

        vm.prank(filler);
        vm.expectRevert("Claim not filled in Tribunal");
        wormholeArbiterArbitrum.multichainBatchSend{value: quoteCost * 2}(batches);
    }

    ///// send test edge cases arbiter side /////

    // test for executor send with invalid emitter address
    function test_executor_send_invalid_emitter_address() public {
        selectFork(CHAIN_ID_BASE);

        // Create a valid payload that would normally work
        Lock[] memory locks = createLocks(1);
        bytes memory payload = this.encodeMessageHelper(
            SPONSOR, NONCE, EXPIRES, WITNESS, locks, ALLOCATOR_DATA, SPONSOR_SIGNATURE, CLAIMANT, 1e18
        );

        // Craft a VAA with a fake emitter address (not the real arbiter address)
        // The real arbiter is at wormholeArbiterBase address, but we'll use a different address
        address fakeEmitter = address(0xdeadbeef);
        bytes32 fakeEmitterAddress = bytes32(uint256(uint160(fakeEmitter)));
        uint16 wormholeArbitrumChainId = WormholeMappings.toWormholeId(42161); // Arbitrum = 23

        // Use craftVaa to create a signed VAA with the fake emitter
        // nonce = 0 for SINGLE_SEND
        bytes memory encodedVaa = coreBridge().craftVaa(wormholeArbitrumChainId, fakeEmitterAddress, payload);

        // Try to deliver this VAA to the REAL arbiter - it should reject because
        // emitter address (fakeEmitter) != address(wormholeArbiterBase)
        vm.expectRevert("Message not from corresponding arbiter");
        wormholeArbiterBase.executeVAAv1(encodedVaa);
    }

    // test for executor send with invalid chain ID (unsupported chain)
    function test_executor_send_invalid_chain_id() public {
        selectFork(CHAIN_ID_BASE);

        // Create a valid payload
        Lock[] memory locks = createLocks(1);
        bytes memory payload = this.encodeMessageHelper(
            SPONSOR, NONCE, EXPIRES, WITNESS, locks, ALLOCATOR_DATA, SPONSOR_SIGNATURE, CLAIMANT, 1e18
        );

        // Craft a VAA with a valid emitter (the real arbiter) but UNSUPPORTED chain ID
        bytes32 realEmitterAddress = bytes32(uint256(uint160(address(wormholeArbiterBase))));
        uint16 unsupportedChainId = 99; // Not in WormholeMappings (supported: 2, 23, 30, 44)

        bytes memory encodedVaa = coreBridge().craftVaa(unsupportedChainId, realEmitterAddress, payload);

        // Should reject because chain ID 99 is not supported
        vm.expectRevert("Unsupported chain");
        wormholeArbiterBase.executeVAAv1(encodedVaa);
    }

    // test for executor send with value not equal to 0 (WormholeExecutor.sol)
    function test_executor_send_value_not_zero() public {
        selectFork(CHAIN_ID_BASE);

        // Create a valid payload and VAA
        Lock[] memory locks = createLocks(1);
        bytes memory payload = this.encodeMessageHelper(
            SPONSOR, NONCE, EXPIRES, WITNESS, locks, ALLOCATOR_DATA, SPONSOR_SIGNATURE, CLAIMANT, 1e18
        );

        bytes32 realEmitterAddress = bytes32(uint256(uint160(address(wormholeArbiterBase))));
        uint16 wormholeArbitrumChainId = WormholeMappings.toWormholeId(42161); // 23

        // Set nonce to 0 (SINGLE_SEND) for valid message type
        coreBridge().setNonce(0);

        bytes memory encodedVaa = coreBridge().craftVaa(wormholeArbitrumChainId, realEmitterAddress, payload);

        // Call with msg.value > 0, should revert from _executeVaaDefaultMsgValueCheck
        vm.expectRevert();
        wormholeArbiterBase.executeVAAv1{value: 1 wei}(encodedVaa);
    }

    // test for executor send with invalid nonce (WormholeExecutor.sol)
    function test_executor_send_invalid_nonce() public {
        selectFork(CHAIN_ID_BASE);

        // Create a valid payload
        Lock[] memory locks = createLocks(1);
        bytes memory payload = this.encodeMessageHelper(
            SPONSOR, NONCE, EXPIRES, WITNESS, locks, ALLOCATOR_DATA, SPONSOR_SIGNATURE, CLAIMANT, 1e18
        );

        bytes32 realEmitterAddress = bytes32(uint256(uint160(address(wormholeArbiterBase))));
        uint16 wormholeArbitrumChainId = WormholeMappings.toWormholeId(42161); // 23

        // Set nonce to 2 (SINGLE_POST) - valid enum but not valid for executor SEND path
        // MessagePackingType: 0=SINGLE_SEND, 1=BATCH_SEND, 2=SINGLE_POST, 3=BATCH_POST
        // Executor only handles SINGLE_SEND and BATCH_SEND
        coreBridge().setNonce(2);

        bytes memory encodedVaa = coreBridge().craftVaa(wormholeArbitrumChainId, realEmitterAddress, payload);

        // Should revert with UnsupportedMessageType because nonce 2 (SINGLE_POST) is not valid for executor
        vm.expectRevert(IWormholeArbiter.UnsupportedMessageType.selector);
        wormholeArbiterBase.executeVAAv1(encodedVaa);
    }

    // test for executor with invalid vaa signature (WormholeExecutor.sol)
    function test_executor_send_invalid_vaa_signature() public {
        selectFork(CHAIN_ID_BASE);

        // Create a valid payload and VAA
        Lock[] memory locks = createLocks(1);
        bytes memory payload = this.encodeMessageHelper(
            SPONSOR, NONCE, EXPIRES, WITNESS, locks, ALLOCATOR_DATA, SPONSOR_SIGNATURE, CLAIMANT, 1e18
        );

        bytes32 realEmitterAddress = bytes32(uint256(uint160(address(wormholeArbiterBase))));
        uint16 wormholeArbitrumChainId = WormholeMappings.toWormholeId(42161);

        coreBridge().setNonce(0); // SINGLE_SEND

        bytes memory encodedVaa = coreBridge().craftVaa(wormholeArbitrumChainId, realEmitterAddress, payload);

        // Corrupt the signature by flipping a byte in the signature area
        // VAA structure: version(1) + guardianSetIndex(4) + sigCount(1) + signatures(66 each)
        // Signatures start at byte 6, flip byte 10 (inside first signature's r value)
        encodedVaa[10] = bytes1(uint8(encodedVaa[10]) ^ 0xFF);

        // Should revert due to invalid signature
        vm.expectRevert(CoreBridgeLib.VerificationFailed.selector);
        wormholeArbiterBase.executeVAAv1(encodedVaa);
    }

    // test for executor batch send with invalid vaa signature (WormholeExecutor.sol)
    function test_executor_batch_send_invalid_vaa_signature() public {
        selectFork(CHAIN_ID_BASE);

        // Create batch payload
        uint256 numClaims = 2;
        BatchClaimWithLocks[] memory claims = new BatchClaimWithLocks[](numClaims);
        bytes32[] memory claimants = new bytes32[](numClaims);
        uint256[] memory scalingFactors = new uint256[](numClaims);

        for (uint256 i = 0; i < numClaims; i++) {
            Lock[] memory locks = createLocks(1);
            claims[i] = createBatchClaimWithLocks(i, locks);
            claimants[i] = bytes32(uint256(CLAIMANT) + i);
            scalingFactors[i] = 1e18;
        }

        bytes memory payload = this.encodeBatchSendHelper(claimants, scalingFactors, claims);

        bytes32 realEmitterAddress = bytes32(uint256(uint160(address(wormholeArbiterBase))));
        uint16 wormholeArbitrumChainId = WormholeMappings.toWormholeId(42161);

        coreBridge().setNonce(1); // BATCH_SEND

        bytes memory encodedVaa = coreBridge().craftVaa(wormholeArbitrumChainId, realEmitterAddress, payload);

        // Corrupt the signature
        encodedVaa[10] = bytes1(uint8(encodedVaa[10]) ^ 0xFF);

        // Should revert due to invalid signature
        vm.expectRevert(CoreBridgeLib.VerificationFailed.selector);
        wormholeArbiterBase.executeVAAv1(encodedVaa);
    }
}
