pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {MockTheCompact} from "test/mocks/MockTheCompact.sol";
import {TribunalMock} from "test/mocks/TribunalMock.sol";
import {WormholeArbiter} from "src/WormholeArbiter.sol";
import {QuoteLib} from "lib/wormhole-solidity-sdk/src/testing/ExecutorTest.sol";
import {WormholeParams, BatchSend, BatchClaimWithLocks} from "src/wormhole/WormholeTypes.sol";

import {Lock, BatchCompact} from "the-compact/src/types/EIP712Types.sol";

import {ExecutorTest} from "wormhole-solidity-sdk/testing/ExecutorTest.sol";
import {WormholeForkTest} from "wormhole-solidity-sdk/testing/WormholeForkTest.sol";
import {CHAIN_ID_ARBITRUM, CHAIN_ID_BASE} from "wormhole-solidity-sdk/constants/Chains.sol";


// for post tests, using this as an example: https://github.com/wormhole-foundation/wormhole-scaffolding/blob/main/evm/forge-test/01_hello_world/HelloWorld.t.sol
// for send tests, using this as an example: https://github.com/wormhole-foundation/wormhole-solidity-sdk/blob/main/test/Executor.t.sol

contract WormholeArbiterTest is ExecutorTest {

    //wormhole arbiters for arbitrum and base
    WormholeArbiter public WormholeArbiterArbitrum;
    WormholeArbiter public WormholeArbiterBase;

    //tribunals for arbitrum and base
    TribunalMock public TribunalMockArbitrum;
    TribunalMock public TribunalMockBase;

    //executor address
    address constant EXECUTOR_ADDRESS_BASE = 0x9E1936E91A4a5AE5A5F75fFc472D6cb8e93597ea;
    address constant EXECUTOR_ADDRESS_ARBITRUM = 0x3980f8318fc03d79033Bbb421A622CDF8d2Eeab4;

    //core bridge address
    address constant CORE_BRIDGE_ADDRESS_BASE = 0xbebdb6C8ddC678FfA9f8748f85C815C556Dd8ac6;
    address constant CORE_BRIDGE_ADDRESS_ARBITRUM = 0xa5f208e072434bC67592E4C49C1B991BA79BCA46;

    //addresses to etch the tribunal and compact mock to
    address constant TRIBUNAL_ADDRESS = 0x0000000000000000000000000000000000001111;
    address constant THE_COMPACT_ADDRESS = 0x00000000000000171ede64904551eeDF3C6C9788;
    MockTheCompact public compactMock;

    //salt for the deterministic addresses
    bytes32 public salt = bytes32(uint256(0x1234));

    //forks for arbitrum and base
    uint256 public ARBITRUM_FORK;
    uint256 public BASE_FORK;

    // create some mock data for the send
    uint256 constant BASE_CHAIN_ID_STANDARD = 8453;
    uint256 constant ARBITRUM_CHAIN_ID_STANDARD = 42161;
    uint128 constant GAS_LIMIT = 1_000_000;

    // claim data
    address constant SPONSOR = 0x1111111111111111111111111111111111111111;
    uint256 constant NONCE = 0x2222222222222222222222222222222222222222222222222222222222222222;
    uint256 constant EXPIRES = 0x3333333333333333333333333333333333333333333333333333333333333333;
    bytes32 constant WITNESS = keccak256("witness");
    bytes32 constant CLAIMANT = 0x9999999999999999999999999999999999999999999999999999999999999999;

    // quote data
    bytes public quote;
    uint256 public quoteCost;
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

    function craftSignedQuote(uint16 dstChain, uint128 gasLimit)
        internal
        view
        virtual
        returns (bytes memory signedQuote, uint256 totalCost)
    {
        // Hardcoded values for testing
        uint64 baseFee = 1e9;
        uint64 destinationGasPrice = 1e9;
        uint64 sourcePrice = 1e9;
        uint64 destinationPrice = 1e9;
        uint64 expiryTime = uint64(block.timestamp + 1 hours);

        signedQuote = QuoteLib.signAndPackQuote(
        QuoteLib.encodeV1Quote(
            quoter,
            payee,
            chainId(),
            dstChain,
            expiryTime,
            baseFee,
            destinationGasPrice,
            sourcePrice,
            destinationPrice
        ),
        quoterSecret
        );

        // Calculate total cost: ((destinationGasPrice × gasLimit × destinationPrice) / sourcePrice) + baseFee
        uint256 destinationCostInUSD = uint256(destinationGasPrice) * gasLimit * uint256(destinationPrice);
        uint256 costInSourceNative = destinationCostInUSD / uint256(sourcePrice);
        totalCost = costInSourceNative + uint256(baseFee);
    }

    function setUp() public override{

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

        // get quote cost (throwaway gas price for now)
        (quote, quoteCost) = craftSignedQuote(CHAIN_ID_BASE, GAS_LIMIT);

        // --- Deploy Tribunal, MockTheCompact, and WormholeArbiter on Base fork ---
        selectFork(CHAIN_ID_BASE);

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
    // TODO: check WormholeExecutor.sol cases too
    // TODO: check for expected calls emits on the lower level contracts
    // TODO: make sure publish and relay sets peer address to the arbiter address
    function test_send_single_send() public {

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

        //send claim TODO check for expected emits
        vm.prank(filler);
        vm.recordLogs();
        WormholeArbiterArbitrum.send{value: quoteCost}(
            BASE_CHAIN_ID_STANDARD, 
            SPONSOR, 
            NONCE, 
            EXPIRES, 
            WITNESS, 
            locks, 
            bytes(""), 
            bytes(""),  
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

        //execute the relay
        executeRelay();

        selectFork(CHAIN_ID_BASE);

        //check that the claim hash is set as marked in the mock compact
        assertTrue(compactMock.getClaimHash(claimHash));

    }

    function test_send_single_send_dispatch_callback() public {
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

        // encode send context
        bytes memory context = WormholeArbiterArbitrum.encodeSendContext(
            bytes(""),
            bytes(""),
            WormholeParams({totalCost: quoteCost, gasLimit: GAS_LIMIT}),
            quote
        );

        // call dispatchCallback on tribunal
        // TODO check for expected emits
        vm.prank(filler);
        vm.recordLogs();
        TribunalMockArbitrum.dispatchCallback{value: quoteCost}(
            BASE_CHAIN_ID_STANDARD,
            compact,
            WITNESS,
            claimHash,
            CLAIMANT,
            1e18,
            new uint256[](0),
            context
        );

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
    function test_send_single_send_fees() public {
    }

    function test_send_batch_send_fees() public {
    }

    function test_send_multichain_batch_send_fees() public {
    }

    ///// send test edge cases trib side ///// 

    // test for dispatch with invalid arbiter

    // test for dispatch with invalid context

    // test for send with invalid claim hash

    // test for send with invalid message fee for publishing (WormholeExecutor.sol)

    // test for send with invalid fee for execution (WormholeExecutor.sol)

    // test for batch send with invalid claim hashes

    // test for batch send with invalid claimants
    
    // test for batch send with invalid size

    // test for multichain batch send with invalid claim hashes (redundant but good to have)

    ///// send test edge cases arbiter side /////

    // test for executor send with invalid emitter address 

    // test for executor send with value not equal to 0 (WormholeExecutor.sol)

    // test for executor send with invalid nonce (WormholeExecutor.sol)

    // for post tests, using this as an example: https://github.com/wormhole-foundation/wormhole-scaffolding/blob/main/evm/forge-test/01_hello_world/HelloWorld.t.sol

    function test_send_post() public {
    }

    function test_send_dispatch_callback() public {
    }

    // will need to verify correct derivation of locks and claims in function itself
    function test_send_batch_post() public {
    }

    function test_send_multichain_batch_post() public {
    }

    function test_send_single_post_fees() public {
    }

    function test_send_batch_post_fees() public {
    }

    function test_send_multichain_batch_post_fees() public {
    }

    ///// post test edge cases trib side ///// 

    // test for dispatch with invalid arbiter

    // test for dispatch with invalid context

    // test for post with invalid claim hash

    // test for post with invalid claimant

    // test for post with invalid fee

    // test for batch post with no claim filled in tribunal

    // test for batch post larger than max batch size

    // test for batch post with invalid fee for publishing (WormholeExecutor.sol)

    // test for multichain batch post with no claim filled in tribunal

    // test for multichain batch post with invalid fee for publishing (WormholeExecutor.sol)

    ///// post test edge cases arbiter side ///// 

    // test for post with invalid emitter address

    // test for post with invalid nonce

    // test for batch post with invalid claim hashes that dont match the derived claim hash
    
    // test to make sure batch post is correctly applying scaling factors
    
    // test to make sure batch post is correctly applying claimants

    // make sure that 


}