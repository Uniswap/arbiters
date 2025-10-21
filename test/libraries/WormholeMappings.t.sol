// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {WormholeMappings} from "../../src/libraries/WormholeMappings.sol";

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

    function getWormholeRelayer(uint256 evmChainId) external pure returns (address) {
        return WormholeMappings.getWormholeRelayer(evmChainId);
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

    // Wormhole Relayer contract addresses
    address constant ETHEREUM_RELAYER = 0x27428DD2d3DD32A4D7f7C497eAaa23130d894911;
    address constant UNICHAIN_RELAYER = 0x27428DD2d3DD32A4D7f7C497eAaa23130d894911;
    address constant BASE_RELAYER = 0x706F82e9bb5b0813501714Ab5974216704980e31;
    address constant ARBITRUM_RELAYER = 0x27428DD2d3DD32A4D7f7C497eAaa23130d894911;

    function setUp() public {
        wrapper = new WormholeMappingsWrapper();
    }

    // ============================================
    // toWormholeId Tests
    // ============================================

    /// @notice Test all EVM chain ID to Wormhole ID mappings
    function test_toWormholeId_allChains() public {
        assertEq(WormholeMappings.toWormholeId(ETHEREUM_EVM_ID), ETHEREUM_WORMHOLE_ID);
        assertEq(WormholeMappings.toWormholeId(UNICHAIN_EVM_ID), UNICHAIN_WORMHOLE_ID);
        assertEq(WormholeMappings.toWormholeId(BASE_EVM_ID), BASE_WORMHOLE_ID);
        assertEq(WormholeMappings.toWormholeId(ARBITRUM_EVM_ID), ARBITRUM_WORMHOLE_ID);
    }

    /// @notice Fuzz test that only supported chains don't revert
    function testFuzz_toWormholeId_onlySupportedChainsSucceed(uint256 evmChainId) public {
        if (
            evmChainId == ETHEREUM_EVM_ID || evmChainId == UNICHAIN_EVM_ID || evmChainId == BASE_EVM_ID
                || evmChainId == ARBITRUM_EVM_ID
        ) {
            wrapper.toWormholeId(evmChainId);
        } else {
            vm.expectRevert("Unsupported chain");
            wrapper.toWormholeId(evmChainId);
        }
    }

    // ============================================
    // toEvmId Tests
    // ============================================

    /// @notice Test all Wormhole ID to EVM chain ID mappings
    function test_toEvmId_allChains() public {
        assertEq(WormholeMappings.toEvmId(ETHEREUM_WORMHOLE_ID), ETHEREUM_EVM_ID);
        assertEq(WormholeMappings.toEvmId(ARBITRUM_WORMHOLE_ID), ARBITRUM_EVM_ID);
        assertEq(WormholeMappings.toEvmId(BASE_WORMHOLE_ID), BASE_EVM_ID);
        assertEq(WormholeMappings.toEvmId(UNICHAIN_WORMHOLE_ID), UNICHAIN_EVM_ID);
    }

    /// @notice Fuzz test that only supported chains don't revert
    function testFuzz_toEvmId_onlySupportedChainsSucceed(uint16 wormholeChainId) public {
        if (
            wormholeChainId == ETHEREUM_WORMHOLE_ID || wormholeChainId == ARBITRUM_WORMHOLE_ID
                || wormholeChainId == BASE_WORMHOLE_ID || wormholeChainId == UNICHAIN_WORMHOLE_ID
        ) {
            wrapper.toEvmId(wormholeChainId);
        } else {
            vm.expectRevert("Unsupported chain");
            wrapper.toEvmId(wormholeChainId);
        }
    }

    // ============================================
    // Bidirectional Mapping Tests
    // ============================================

    /// @notice Test bidirectional mapping preserves values for all chains
    function test_bidirectionalMapping() public {
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
    function test_getWormhole_allChains() public {
        assertEq(WormholeMappings.getWormhole(ETHEREUM_EVM_ID), ETHEREUM_WORMHOLE);
        assertEq(WormholeMappings.getWormhole(UNICHAIN_EVM_ID), UNICHAIN_WORMHOLE);
        assertEq(WormholeMappings.getWormhole(BASE_EVM_ID), BASE_WORMHOLE);
        assertEq(WormholeMappings.getWormhole(ARBITRUM_EVM_ID), ARBITRUM_WORMHOLE);
    }

    /// @notice Fuzz test that only supported chains don't revert for getWormhole
    function testFuzz_getWormhole_onlySupportedChainsSucceed(uint256 evmChainId) public {
        if (
            evmChainId == ETHEREUM_EVM_ID || evmChainId == UNICHAIN_EVM_ID || evmChainId == BASE_EVM_ID
                || evmChainId == ARBITRUM_EVM_ID
        ) {
            address wormhole = wrapper.getWormhole(evmChainId);
            assertTrue(wormhole != address(0));
        } else {
            vm.expectRevert("Unsupported chain");
            wrapper.getWormhole(evmChainId);
        }
    }

    // ============================================
    // getWormholeRelayer Tests
    // ============================================

    /// @notice Test Wormhole Relayer contract addresses for all chains
    function test_getWormholeRelayer_allChains() public {
        assertEq(WormholeMappings.getWormholeRelayer(ETHEREUM_EVM_ID), ETHEREUM_RELAYER);
        assertEq(WormholeMappings.getWormholeRelayer(UNICHAIN_EVM_ID), UNICHAIN_RELAYER);
        assertEq(WormholeMappings.getWormholeRelayer(BASE_EVM_ID), BASE_RELAYER);
        assertEq(WormholeMappings.getWormholeRelayer(ARBITRUM_EVM_ID), ARBITRUM_RELAYER);
    }

    /// @notice Fuzz test that only supported chains don't revert for getWormholeRelayer
    function testFuzz_getWormholeRelayer_onlySupportedChainsSucceed(uint256 evmChainId) public {
        if (
            evmChainId == ETHEREUM_EVM_ID || evmChainId == UNICHAIN_EVM_ID || evmChainId == BASE_EVM_ID
                || evmChainId == ARBITRUM_EVM_ID
        ) {
            address relayer = wrapper.getWormholeRelayer(evmChainId);
            assertTrue(relayer != address(0));
        } else {
            vm.expectRevert("Unsupported chain");
            wrapper.getWormholeRelayer(evmChainId);
        }
    }

}
