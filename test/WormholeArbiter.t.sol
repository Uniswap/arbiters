pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {MockTheCompact} from "test/mocks/MockTheCompact.sol";
import {TribunalMock} from "test/mocks/TribunalMock.sol";
import {WormholeArbiter} from "src/WormholeArbiter.sol";

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

    function setUp() public override{

        //set up the forks
        setUpFork(CHAIN_ID_ARBITRUM, vm.envString("ARBITRUM_RPC_URL"));
        setUpFork(CHAIN_ID_BASE, vm.envString("BASE_RPC_URL"));

        // --- Deploy Tribunal and WormholeArbiter on Arbitrum fork ---
        selectFork(CHAIN_ID_ARBITRUM);

        // Deploy TribunalMock and set its code to TRIBUNAL_ADDRESS
        TribunalMock arbitrumTribunalMock = new TribunalMock();
        vm.etch(TRIBUNAL_ADDRESS, address(arbitrumTribunalMock).code);
        TribunalMockArbitrum = TribunalMock(TRIBUNAL_ADDRESS);

        // Deploy WormholeArbiter at deterministic address
        WormholeArbiterArbitrum = new WormholeArbiter{salt: salt}();

        // --- Deploy Tribunal, MockTheCompact, and WormholeArbiter on Base fork ---
        selectFork(CHAIN_ID_BASE);

        // Deploy TribunalMock and set its code to TRIBUNAL_ADDRESS
        TribunalMock baseTribunalMock = new TribunalMock();
        vm.etch(TRIBUNAL_ADDRESS, address(baseTribunalMock).code);
        TribunalMockBase = TribunalMock(TRIBUNAL_ADDRESS);

        // Deploy WormholeArbiter at deterministic address
        WormholeArbiterBase = new WormholeArbiter{salt: salt}();

        // deploy the compact mock
        compactMock = new MockTheCompact();
        vm.etch(THE_COMPACT_ADDRESS, address(compactMock).code);
        compactMock = MockTheCompact(THE_COMPACT_ADDRESS);
    }

    function test_deployments_success() public {
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
    // it works. will need to test message fees and gas limits too
    function test_send_single_send() public {
    }

    function test_send_single_send_dispatch_callback() public {
    }
    
    function test_send_batch_send() public {
    }

    function test_send_multichain_batch_send() public {
    }

    // for post tests, using this as an example: https://github.com/wormhole-foundation/wormhole-scaffolding/blob/main/evm/forge-test/01_hello_world/HelloWorld.t.sol

    function test_send_post() public {
    }

    function test_send_dispatch_callback() public {
    }

    function test_send_batch_post() public {
    }

    function test_send_multichain_batch_post() public {
    }

    // for future test we want to set message fees setMessageFee(10 gwei);
}