// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {WormholeMappings} from "../../src/wormhole/WormholeMappings.sol";

/// @title WormholeMappingsWrapper
/// @notice Wrapper contract to call WormholeMappings library functions in tests
/// @dev Needed to properly test revert cases with vm.expectRevert
contract WormholeMappingsWrapper {
    function toWormholeId(uint256 evmChainId) external pure returns (uint16) {
        return WormholeMappings.toWormholeId(evmChainId);
    }

    function toEvmId(uint16 wormholeChainId) external pure returns (uint256) {
        return WormholeMappings.toEvmId(wormholeChainId);
    }

    function getWormhole(uint256 evmChainId) external pure returns (address) {
        return WormholeMappings.getWormhole(evmChainId);
    }

    function getWormholeExecutor(uint256 evmChainId) external pure returns (address) {
        return WormholeMappings.getWormholeExecutor(evmChainId);
    }

    function validateChainId(uint16 wormholeChainId) external pure {
        WormholeMappings.validateChainId(wormholeChainId);
    }
}

/// @title WormholeMappingsTest
/// @notice Comprehensive test suite for the WormholeMappings library
/// @dev Tests all hardcoded chain ID mappings and contract addresses
contract WormholeMappingsTest is Test {
    WormholeMappingsWrapper public wrapper;
    // Chain ID constants
    uint256 constant ETHEREUM_EVM_ID = 1;
    uint256 constant UNICHAIN_EVM_ID = 130;
    uint256 constant BASE_EVM_ID = 8453;
    uint256 constant ARBITRUM_EVM_ID = 42161;

    uint16 constant ETHEREUM_WORMHOLE_ID = 2;
    uint16 constant ARBITRUM_WORMHOLE_ID = 23;
    uint16 constant BASE_WORMHOLE_ID = 30;
    uint16 constant UNICHAIN_WORMHOLE_ID = 44;

    // Wormhole Core contract addresses
    address constant ETHEREUM_WORMHOLE = 0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B;
    address constant UNICHAIN_WORMHOLE = 0xCa1D5a146B03f6303baF59e5AD5615ae0b9d146D;
    address constant BASE_WORMHOLE = 0xbebdb6C8ddC678FfA9f8748f85C815C556Dd8ac6;
    address constant ARBITRUM_WORMHOLE = 0xa5f208e072434bC67592E4C49C1B991BA79BCA46;

    // Wormhole Executor contract addresses
    address constant ETHEREUM_EXECUTOR = 0x84EEe8dBa37C36947397E1E11251cA9A06Fc6F8a;
    address constant UNICHAIN_EXECUTOR = 0x764dD868eAdD27ce57BCB801E4ca4a193d231Aed;
    address constant BASE_EXECUTOR = 0x9E1936E91A4a5AE5A5F75fFc472D6cb8e93597ea;
    address constant ARBITRUM_EXECUTOR = 0x3980f8318fc03d79033Bbb421A622CDF8d2Eeab4;

    function setUp() public {
        wrapper = new WormholeMappingsWrapper();
    }

    // ============================================
    // toWormholeId Tests
    // ============================================

    /// @notice Test all EVM chain ID to Wormhole ID mappings
    function test_toWormholeId_allChains() public pure {
        assertEq(WormholeMappings.toWormholeId(ETHEREUM_EVM_ID), ETHEREUM_WORMHOLE_ID);
        assertEq(WormholeMappings.toWormholeId(UNICHAIN_EVM_ID), UNICHAIN_WORMHOLE_ID);
        assertEq(WormholeMappings.toWormholeId(BASE_EVM_ID), BASE_WORMHOLE_ID);
        assertEq(WormholeMappings.toWormholeId(ARBITRUM_EVM_ID), ARBITRUM_WORMHOLE_ID);
    }

    // ============================================
    // toEvmId Tests
    // ============================================

    /// @notice Test all Wormhole ID to EVM chain ID mappings
    function test_toEvmId_allChains() public pure {
        assertEq(WormholeMappings.toEvmId(ETHEREUM_WORMHOLE_ID), ETHEREUM_EVM_ID);
        assertEq(WormholeMappings.toEvmId(ARBITRUM_WORMHOLE_ID), ARBITRUM_EVM_ID);
        assertEq(WormholeMappings.toEvmId(BASE_WORMHOLE_ID), BASE_EVM_ID);
        assertEq(WormholeMappings.toEvmId(UNICHAIN_WORMHOLE_ID), UNICHAIN_EVM_ID);
    }

    // ============================================
    // Bidirectional Mapping Tests
    // ============================================

    /// @notice Test bidirectional mapping preserves values for all chains
    function test_bidirectionalMapping() public pure {
        // EVM -> Wormhole -> EVM
        assertEq(WormholeMappings.toEvmId(WormholeMappings.toWormholeId(ETHEREUM_EVM_ID)), ETHEREUM_EVM_ID);
        assertEq(WormholeMappings.toEvmId(WormholeMappings.toWormholeId(UNICHAIN_EVM_ID)), UNICHAIN_EVM_ID);
        assertEq(WormholeMappings.toEvmId(WormholeMappings.toWormholeId(BASE_EVM_ID)), BASE_EVM_ID);
        assertEq(WormholeMappings.toEvmId(WormholeMappings.toWormholeId(ARBITRUM_EVM_ID)), ARBITRUM_EVM_ID);

        // Wormhole -> EVM -> Wormhole
        assertEq(WormholeMappings.toWormholeId(WormholeMappings.toEvmId(ETHEREUM_WORMHOLE_ID)), ETHEREUM_WORMHOLE_ID);
        assertEq(WormholeMappings.toWormholeId(WormholeMappings.toEvmId(UNICHAIN_WORMHOLE_ID)), UNICHAIN_WORMHOLE_ID);
        assertEq(WormholeMappings.toWormholeId(WormholeMappings.toEvmId(BASE_WORMHOLE_ID)), BASE_WORMHOLE_ID);
        assertEq(WormholeMappings.toWormholeId(WormholeMappings.toEvmId(ARBITRUM_WORMHOLE_ID)), ARBITRUM_WORMHOLE_ID);
    }

    // ============================================
    // getWormhole Tests
    // ============================================

    /// @notice Test Wormhole Core contract addresses for all chains
    function test_getWormhole_allChains() public pure {
        assertEq(WormholeMappings.getWormhole(ETHEREUM_EVM_ID), ETHEREUM_WORMHOLE);
        assertEq(WormholeMappings.getWormhole(UNICHAIN_EVM_ID), UNICHAIN_WORMHOLE);
        assertEq(WormholeMappings.getWormhole(BASE_EVM_ID), BASE_WORMHOLE);
        assertEq(WormholeMappings.getWormhole(ARBITRUM_EVM_ID), ARBITRUM_WORMHOLE);
    }

    // ============================================
    // getWormholeExecutor Tests
    // ============================================

    /// @notice Test Wormhole Executor contract addresses for all chains
    function test_getWormholeExecutor_allChains() public pure {
        assertEq(WormholeMappings.getWormholeExecutor(ETHEREUM_EVM_ID), ETHEREUM_EXECUTOR);
        assertEq(WormholeMappings.getWormholeExecutor(UNICHAIN_EVM_ID), UNICHAIN_EXECUTOR);
        assertEq(WormholeMappings.getWormholeExecutor(BASE_EVM_ID), BASE_EXECUTOR);
        assertEq(WormholeMappings.getWormholeExecutor(ARBITRUM_EVM_ID), ARBITRUM_EXECUTOR);
    }

    // ============================================
    // validateChainId Tests
    // ============================================

    /// @notice Test validateChainId accepts all supported chains
    function test_validateChainId_allSupportedChains() public pure {
        // All supported chains should not revert
        WormholeMappings.validateChainId(ETHEREUM_WORMHOLE_ID);
        WormholeMappings.validateChainId(ARBITRUM_WORMHOLE_ID);
        WormholeMappings.validateChainId(BASE_WORMHOLE_ID);
        WormholeMappings.validateChainId(UNICHAIN_WORMHOLE_ID);
    }

    /// @notice Test validateChainId reverts on unsupported Wormhole chain IDs
    function test_validateChainId_revertsOnUnsupportedChain() public {
        // Test various unsupported Wormhole chain IDs
        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 0));
        wrapper.validateChainId(0);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 1));
        wrapper.validateChainId(1);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 3));
        wrapper.validateChainId(3);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 22));
        wrapper.validateChainId(22);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 24));
        wrapper.validateChainId(24);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 29));
        wrapper.validateChainId(29);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 31));
        wrapper.validateChainId(31);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 43));
        wrapper.validateChainId(43);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 45));
        wrapper.validateChainId(45);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 100));
        wrapper.validateChainId(100);
    }

    /// @notice Fuzz test: verify arbitrary unsupported Wormhole chain IDs revert
    function testFuzz_validateChainId_revertsOnUnsupportedChain(uint16 wormholeChainId) public {
        // Skip supported chain IDs
        vm.assume(
            wormholeChainId != ETHEREUM_WORMHOLE_ID && wormholeChainId != ARBITRUM_WORMHOLE_ID
                && wormholeChainId != BASE_WORMHOLE_ID && wormholeChainId != UNICHAIN_WORMHOLE_ID
        );

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, wormholeChainId));
        wrapper.validateChainId(wormholeChainId);
    }

    // ============================================
    // Unsupported Chain ID Revert Tests
    // ============================================

    /// @notice Test toWormholeId reverts on unsupported EVM chain IDs
    function test_toWormholeId_revertsOnUnsupportedChain() public {
        // Test various unsupported chain IDs
        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 0));
        wrapper.toWormholeId(0);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 2));
        wrapper.toWormholeId(2);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 129));
        wrapper.toWormholeId(129);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 131));
        wrapper.toWormholeId(131);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 8452));
        wrapper.toWormholeId(8452);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 8454));
        wrapper.toWormholeId(8454);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 42160));
        wrapper.toWormholeId(42160);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 42162));
        wrapper.toWormholeId(42162);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 999999));
        wrapper.toWormholeId(999999);
    }

    /// @notice Test toEvmId reverts on unsupported Wormhole chain IDs
    function test_toEvmId_revertsOnUnsupportedChain() public {
        // Test various unsupported Wormhole chain IDs
        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 0));
        wrapper.toEvmId(0);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 1));
        wrapper.toEvmId(1);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 3));
        wrapper.toEvmId(3);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 22));
        wrapper.toEvmId(22);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 24));
        wrapper.toEvmId(24);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 29));
        wrapper.toEvmId(29);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 31));
        wrapper.toEvmId(31);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 43));
        wrapper.toEvmId(43);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 45));
        wrapper.toEvmId(45);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, 100));
        wrapper.toEvmId(100);
    }

    /// @notice Test getWormhole reverts on unsupported EVM chain IDs
    function test_getWormhole_revertsOnUnsupportedChain() public {
        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 0));
        wrapper.getWormhole(0);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 2));
        wrapper.getWormhole(2);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 10));
        wrapper.getWormhole(10);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 137));
        wrapper.getWormhole(137); // Polygon

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 56));
        wrapper.getWormhole(56); // BSC
    }

    /// @notice Test getWormholeExecutor reverts on unsupported EVM chain IDs
    function test_getWormholeExecutor_revertsOnUnsupportedChain() public {
        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 0));
        wrapper.getWormholeExecutor(0);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 2));
        wrapper.getWormholeExecutor(2);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 10));
        wrapper.getWormholeExecutor(10);

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 137));
        wrapper.getWormholeExecutor(137); // Polygon

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, 56));
        wrapper.getWormholeExecutor(56); // BSC
    }

    /// @notice Fuzz test: verify arbitrary unsupported chain IDs revert
    function testFuzz_toWormholeId_revertsOnUnsupportedChain(uint256 evmChainId) public {
        // Skip supported chain IDs
        vm.assume(
            evmChainId != ETHEREUM_EVM_ID && evmChainId != UNICHAIN_EVM_ID && evmChainId != BASE_EVM_ID
                && evmChainId != ARBITRUM_EVM_ID
        );

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, evmChainId));
        wrapper.toWormholeId(evmChainId);
    }

    /// @notice Fuzz test: verify arbitrary unsupported Wormhole chain IDs revert
    function testFuzz_toEvmId_revertsOnUnsupportedChain(uint16 wormholeChainId) public {
        // Skip supported chain IDs
        vm.assume(
            wormholeChainId != ETHEREUM_WORMHOLE_ID && wormholeChainId != ARBITRUM_WORMHOLE_ID
                && wormholeChainId != BASE_WORMHOLE_ID && wormholeChainId != UNICHAIN_WORMHOLE_ID
        );

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedWormholeChain.selector, wormholeChainId));
        wrapper.toEvmId(wormholeChainId);
    }

    /// @notice Fuzz test: verify arbitrary unsupported chain IDs revert for getWormhole
    function testFuzz_getWormhole_revertsOnUnsupportedChain(uint256 evmChainId) public {
        // Skip supported chain IDs
        vm.assume(
            evmChainId != ETHEREUM_EVM_ID && evmChainId != UNICHAIN_EVM_ID && evmChainId != BASE_EVM_ID
                && evmChainId != ARBITRUM_EVM_ID
        );

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, evmChainId));
        wrapper.getWormhole(evmChainId);
    }

    /// @notice Fuzz test: verify arbitrary unsupported chain IDs revert for getWormholeExecutor
    function testFuzz_getWormholeExecutor_revertsOnUnsupportedChain(uint256 evmChainId) public {
        // Skip supported chain IDs
        vm.assume(
            evmChainId != ETHEREUM_EVM_ID && evmChainId != UNICHAIN_EVM_ID && evmChainId != BASE_EVM_ID
                && evmChainId != ARBITRUM_EVM_ID
        );

        vm.expectRevert(abi.encodeWithSelector(WormholeMappings.UnsupportedEvmChain.selector, evmChainId));
        wrapper.getWormholeExecutor(evmChainId);
    }
}
