pragma solidity ^0.8.13;

import {MockTheCompact} from "test/mocks/MockTheCompact.sol";
import {TribunalMock} from "test/mocks/TribunalMock.sol";
import {WormholeArbiter} from "src/WormholeArbiter.sol";
import {BaseArbiter} from "src/abstracts/BaseArbiter.sol";
import {QuoteLib} from "lib/wormhole-solidity-sdk/src/testing/ExecutorTest.sol";
import {WormholeParams, BatchSend, BatchClaimWithLocks} from "src/wormhole/WormholeTypes.sol";
import {BatchClaim} from "the-compact/src/types/BatchClaims.sol";
import {BatchClaimComponent, Component} from "the-compact/src/types/Components.sol";
import {Lock, BatchCompact} from "the-compact/src/types/EIP712Types.sol";
import {WITNESS_TYPESTRING} from "tribunal/types/TribunalTypeHashes.sol";
import {ExecutorTest} from "wormhole-solidity-sdk/testing/ExecutorTest.sol";
import {CHAIN_ID_ARBITRUM, CHAIN_ID_BASE} from "wormhole-solidity-sdk/constants/Chains.sol";

// to understand how these tests work, see the example at: https://github.com/wormhole-foundation/wormhole-solidity-sdk/blob/main/test/Executor.t.sol
// Similar to the example, this test uses the executor test harness from the wormhole-solidity-sdk at lib/wormhole-solidity-sdk/src/testing/ExecutorTest.sol
// it forks arbitrum and base, deploys the arbiters and tribunals, and then tests the send flow on both forks.
// the ExecutorTest harness deals with the execution of the relay and the verification of the VAA and overwrites
// the coreBridge to a new set of Guardian keys to allow signing the VAA with the new guardian keys.

contract WormholeArbiterTest is ExecutorTest {
    /* forge-lint-disable mixed-case-variable */

    WormholeArbiter public WormholeArbiterArbitrum;
    WormholeArbiter public WormholeArbiterBase;

    TribunalMock public TribunalMockArbitrum;
    TribunalMock public TribunalMockBase;

    MockTheCompact public compactMock;
    address constant THE_COMPACT_ADDRESS = 0x00000000000000171ede64904551eeDF3C6C9788; //compact address to etch to

    // constants plus mock data for the send
    bytes32 public salt = bytes32(uint256(0x1234));
    uint256 constant BASE_CHAIN_ID_STANDARD = 8453;
    uint128 constant GAS_LIMIT = 2_000_000;
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

    function setUp() public override {
        setUpFork(CHAIN_ID_ARBITRUM, vm.envString("ARBITRUM_RPC_URL"));
        setUpFork(CHAIN_ID_BASE, vm.envString("BASE_RPC_URL"));

        selectFork(CHAIN_ID_ARBITRUM);

        filler = makeAddr("filler");
        vm.deal(filler, 5 ether);

        // deploy wormhole arbiter + etch tribunal with TribunalMock on Arb
        WormholeArbiterArbitrum = new WormholeArbiter{salt: salt}();
        address TRIBUNAL_ADDRESS = WormholeArbiterArbitrum.TRIBUNAL_ADDRESS();
        TribunalMock arbitrumTribunalMock = new TribunalMock();
        vm.etch(TRIBUNAL_ADDRESS, address(arbitrumTribunalMock).code);
        TribunalMockArbitrum = TribunalMock(TRIBUNAL_ADDRESS);

        // get quote cost (throwaway gas price for now)
        (quote, quoteCost) = craftSignedQuote(CHAIN_ID_BASE, GAS_LIMIT);

        selectFork(CHAIN_ID_BASE);

        // deploy wormhole arbiter + etch tribunal with TribunalMock
        WormholeArbiterBase = new WormholeArbiter{salt: salt}();
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

    // TODO: check WormholeExecutor.sol cases too
    // TODO: check for expected calls emits on the lower level contracts
    // TODO: make sure publish and relay sets peer address to the arbiter address
    function test_send_single_send() public {
        selectFork(CHAIN_ID_ARBITRUM);
        setMessageFee(0 gwei); // for this test, message fees will be 0, will be tested later

        // create single lock + get claim hash + set in mock tribunal
        Lock[] memory locks = createLocks(1);
        bytes32 claimHash = WormholeArbiterArbitrum.deriveClaimHash(SPONSOR, NONCE, EXPIRES, WITNESS, locks);
        TribunalMockArbitrum.setFilled(claimHash, CLAIMANT);

        // filler sends the claim (TODO: check for expected emits)
        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.send{
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
        vm.expectCall(address(WormholeArbiterBase), abi.encodeWithSignature("executeVAAv1(bytes)"), 1);

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
            1e18 // no scaling
        );
    }

    function test_send_single_send_dispatch_callback() public {
        // set to arbitrum
        selectFork(CHAIN_ID_ARBITRUM);

        // set message fees to 0
        setMessageFee(0 gwei);

        // create single lock
        Lock[] memory locks = createLocks(1);

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

        // encode send context
        bytes memory context = WormholeArbiterArbitrum.encodeSendContext(
            bytes(""), bytes(""), WormholeParams({totalCost: quoteCost, gasLimit: GAS_LIMIT}), quote
        );

        // call dispatchCallback on tribunal
        // TODO check for expected emits
        vm.prank(filler);
        vm.recordLogs();
        TribunalMockArbitrum.dispatchCallback{
            value: quoteCost
        }(BASE_CHAIN_ID_STANDARD, compact, WITNESS, claimHash, CLAIMANT, 1e18, new uint256[](0), context);

        // check that the filler has quote amount less eth on arbitrum
        assertEq(address(filler).balance, 5 ether - uint256(quoteCost));

        // Switch to base and verify claim hash is not set yet
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash));

        // Set expectation for 1 call to arbiter
        vm.expectCall(address(WormholeArbiterBase), abi.encodeWithSignature("executeVAAv1(bytes)"), 1);

        // Switch back to arbitrum to execute the relay
        selectFork(CHAIN_ID_ARBITRUM);

        // execute the relay
        executeRelay();

        selectFork(CHAIN_ID_BASE);

        // check that the claim hash is set as marked in the mock compact
        assertTrue(compactMock.getClaimHash(claimHash));
    }

    function test_send_batch_send() public {
        // set to arbitrum
        selectFork(CHAIN_ID_ARBITRUM);

        // set message fees to 0
        setMessageFee(0 gwei);

        // Create 2 batch claims with different data
        Lock[] memory locks1 = createLocks(1);
        Lock[] memory locks2 = createLocks(3);

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

        // Construct BatchClaimWithLocks array
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

        // Construct BatchSend
        BatchSend memory batch = BatchSend({
            chainId: BASE_CHAIN_ID_STANDARD,
            claims: claims,
            gasLimit: GAS_LIMIT,
            totalCost: quoteCost,
            signedQuote: quote
        });

        // Send batch claim
        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.batchSend{value: quoteCost}(batch);

        // Check that the filler has quote amount less eth on arbitrum
        assertEq(address(filler).balance, 5 ether - uint256(quoteCost));

        // Switch to base and verify claim hashes are not set yet
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash1));
        assertFalse(compactMock.getClaimHash(claimHash2));

        // Set expectation for 1 call to arbiter
        vm.expectCall(address(WormholeArbiterBase), abi.encodeWithSignature("executeVAAv1(bytes)"), 1);

        // Switch back to arbitrum to execute the relay
        selectFork(CHAIN_ID_ARBITRUM);

        // Execute the relay
        executeRelay();

        selectFork(CHAIN_ID_BASE);

        // Check that both claim hashes are set as marked in the mock compact
        assertTrue(compactMock.getClaimHash(claimHash1));
        assertTrue(compactMock.getClaimHash(claimHash2));
    }

    function test_send_multichain_batch_send() public {
        // set to arbitrum
        selectFork(CHAIN_ID_ARBITRUM);

        // set message fees to 0
        setMessageFee(0 gwei);

        // Create 4 claims with different data
        Lock[] memory locks1 = createLocks(1);
        Lock[] memory locks2 = createLocks(3);
        Lock[] memory locks3 = createLocks(1);
        Lock[] memory locks4 = createLocks(3);

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

        // Construct first BatchSend with 2 claims (claims 1 and 2)
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

        // Construct second BatchSend with 2 claims (claims 3 and 4)
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

        // Construct BatchSend array - both targeting BASE chain
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

        // Send multichain batch
        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.multichainBatchSend{value: quoteCost * 2}(batches);

        // Check that the filler has 2x quote amount less eth on arbitrum
        assertEq(address(filler).balance, 5 ether - uint256(quoteCost * 2));

        // Switch to base and verify all claim hashes are not set yet
        selectFork(CHAIN_ID_BASE);
        assertFalse(compactMock.getClaimHash(claimHash1));
        assertFalse(compactMock.getClaimHash(claimHash2));
        assertFalse(compactMock.getClaimHash(claimHash3));
        assertFalse(compactMock.getClaimHash(claimHash4));

        // Record initial call count
        uint256 initialCallCount = compactMock.getCallCount();

        // Switch to Base and set expectation for 2 calls to arbiter (one per batch)
        selectFork(CHAIN_ID_BASE);
        vm.expectCall(address(WormholeArbiterBase), abi.encodeWithSignature("executeVAAv1(bytes)"), 2);

        // Switch back to arbitrum to execute the relays
        selectFork(CHAIN_ID_ARBITRUM);

        // Execute the relay which relays them all
        executeRelay();

        selectFork(CHAIN_ID_BASE);

        // Check that all 4 claim hashes are set as marked in the mock compact
        assertTrue(compactMock.getClaimHash(claimHash1));
        assertTrue(compactMock.getClaimHash(claimHash2));
        assertTrue(compactMock.getClaimHash(claimHash3));
        assertTrue(compactMock.getClaimHash(claimHash4));

        // Verify call count increased by 4 (2 claims per batch, 2 batches)
        assertEq(compactMock.getCallCount(), initialCallCount + 4);
    }

    // we want to set message fees setMessageFee(10 gwei); before sending
    // also test eth refunds
    function test_send_single_send_fees() public {}

    function test_send_batch_send_fees() public {}

    function test_send_multichain_batch_send_fees() public {}

    ///// send test edge cases trib side /////

    // test for dispatch with invalid arbiter
    function test_send_dispatch_invalid_arbiter() public {}

    // test for dispatch with invalid context
    function test_send_dispatch_invalid_context() public {}

    // test for send with invalid claim hash
    function test_send_invalid_claim_hash() public {}

    // test for send with invalid message fee for publishing (WormholeExecutor.sol)
    function test_send_invalid_message_fee_publishing() public {}

    // test for send with invalid fee for execution (WormholeExecutor.sol)
    function test_send_invalid_fee_execution() public {}

    // test for batch send with invalid claim hashes
    function test_batch_send_invalid_claim_hashes() public {}

    // test for batch send with invalid claimants
    function test_batch_send_invalid_claimants() public {}

    // test for batch send with invalid size
    function test_batch_send_invalid_size() public {}

    // test for multichain batch send with invalid claim hashes (redundant but good to have)
    function test_multichain_batch_send_invalid_claim_hashes() public {}

    ///// send test edge cases arbiter side /////

    // test for executor send with invalid emitter address
    function test_executor_send_invalid_emitter_address() public {}

    // test for executor send with invalid chain ID (unsupported chain)
    function test_executor_send_invalid_chain_id() public {
        // TODO: Mock executeVAAv1 to pass an unsupported Wormhole chain ID (e.g., 99)
        // Expect revert with "Unsupported chain"
        // This tests _executeVaa's chain ID validation
    }

    // test for batch send with invalid chain ID (unsupported chain)
    function test_executor_batch_send_invalid_chain_id() public {
        // TODO: Mock executeVAAv1 to pass an unsupported Wormhole chain ID (e.g., 99)
        // Expect revert with "Unsupported chain"
        // This tests _executeVaa's chain ID validation for batch messages
    }

    // test for executor send with value not equal to 0 (WormholeExecutor.sol)
    function test_executor_send_value_not_zero() public {}

    // test for executor send with invalid nonce (WormholeExecutor.sol)
    function test_executor_send_invalid_nonce() public {}

    // test for executor with invalid vaa signature (WormholeExecutor.sol)
    function test_executor_send_invalid_vaa_signature() public {}

    // test for executor batch send with invalid vaa signature (WormholeExecutor.sol)
    function test_executor_batch_send_invalid_vaa_signature() public {}
}
