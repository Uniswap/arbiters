//SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library WormholeMappings {
    // EVM Chain IDs
    uint256 private constant ETHEREUM_CHAIN_ID = 1;
    uint256 private constant ARBITRUM_CHAIN_ID = 42161;
    uint256 private constant BASE_CHAIN_ID = 8453;
    uint256 private constant UNICHAIN_CHAIN_ID = 130;

    // Wormhole Chain IDs
    uint16 private constant WORMHOLE_ETHEREUM = 2;
    uint16 private constant WORMHOLE_ARBITRUM = 23;
    uint16 private constant WORMHOLE_BASE = 30;
    uint16 private constant WORMHOLE_UNICHAIN = 44;

    // Wormhole Core Addresses
    address private constant WORMHOLE_CORE_ETHEREUM = 0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B;
    address private constant WORMHOLE_CORE_ARBITRUM = 0xa5f208e072434bC67592E4C49C1B991BA79BCA46;
    address private constant WORMHOLE_CORE_BASE = 0xbebdb6C8ddC678FfA9f8748f85C815C556Dd8ac6;
    address private constant WORMHOLE_CORE_UNICHAIN = 0xCa1D5a146B03f6303baF59e5AD5615ae0b9d146D;

    // Wormhole Executor Addresses
    address private constant WORMHOLE_EXECUTOR_ETHEREUM = 0x84EEe8dBa37C36947397E1E11251cA9A06Fc6F8a;
    address private constant WORMHOLE_EXECUTOR_ARBITRUM = 0x3980f8318fc03d79033Bbb421A622CDF8d2Eeab4;
    address private constant WORMHOLE_EXECUTOR_BASE = 0x9E1936E91A4a5AE5A5F75fFc472D6cb8e93597ea;
    address private constant WORMHOLE_EXECUTOR_UNICHAIN = 0x764dD868eAdD27ce57BCB801E4ca4a193d231Aed;

    error UnsupportedEvmChain(uint256 chainId);
    error UnsupportedWormholeChain(uint16 chainId);

    /// @notice Convert EVM chain ID to Wormhole chain ID
    /// @dev Max 3 comparisons (~45 gas) for 4 chains
    /// @return wormholeChainId The corresponding Wormhole chain ID
    function toWormholeId(uint256 evmChainId) internal pure returns (uint16) {
        if (evmChainId <= UNICHAIN_CHAIN_ID) {
            if (evmChainId == ETHEREUM_CHAIN_ID) return WORMHOLE_ETHEREUM;
            if (evmChainId == UNICHAIN_CHAIN_ID) return WORMHOLE_UNICHAIN;
        } else {
            if (evmChainId == BASE_CHAIN_ID) return WORMHOLE_BASE;
            if (evmChainId == ARBITRUM_CHAIN_ID) return WORMHOLE_ARBITRUM;
        }
        revert UnsupportedEvmChain(evmChainId);
    }

    /// @notice Convert Wormhole chain ID to EVM chain ID
    /// @dev Max 3 comparisons (~45 gas) for 4 chains
    /// @return evmChainId The corresponding EVM chain ID
    function toEvmId(uint16 wormholeChainId) internal pure returns (uint256) {
        if (wormholeChainId <= WORMHOLE_ARBITRUM) {
            if (wormholeChainId == WORMHOLE_ETHEREUM) return ETHEREUM_CHAIN_ID;
            if (wormholeChainId == WORMHOLE_ARBITRUM) return ARBITRUM_CHAIN_ID;
        } else {
            if (wormholeChainId == WORMHOLE_BASE) return BASE_CHAIN_ID;
            if (wormholeChainId == WORMHOLE_UNICHAIN) return UNICHAIN_CHAIN_ID;
        }
        revert UnsupportedWormholeChain(wormholeChainId);
    }

    /// @notice Get Wormhole Core contract address by EVM chain ID
    /// @dev Max 3 comparisons (~45 gas) for 4 chains
    /// @return wormholeCore The Wormhole Core contract address
    function getWormhole(uint256 evmChainId) internal pure returns (address) {
        if (evmChainId <= UNICHAIN_CHAIN_ID) {
            if (evmChainId == ETHEREUM_CHAIN_ID) return WORMHOLE_CORE_ETHEREUM;
            if (evmChainId == UNICHAIN_CHAIN_ID) return WORMHOLE_CORE_UNICHAIN;
        } else {
            if (evmChainId == BASE_CHAIN_ID) return WORMHOLE_CORE_BASE;
            if (evmChainId == ARBITRUM_CHAIN_ID) return WORMHOLE_CORE_ARBITRUM;
        }
        revert UnsupportedEvmChain(evmChainId);
    }

    /// @notice Get Wormhole Executor contract address by EVM chain ID
    /// @dev Max 3 comparisons (~45 gas) for 4 chains
    /// @return executor The Wormhole Executor contract address
    function getWormholeExecutor(uint256 evmChainId) internal pure returns (address) {
        if (evmChainId <= UNICHAIN_CHAIN_ID) {
            if (evmChainId == ETHEREUM_CHAIN_ID) return WORMHOLE_EXECUTOR_ETHEREUM;
            if (evmChainId == UNICHAIN_CHAIN_ID) return WORMHOLE_EXECUTOR_UNICHAIN;
        } else {
            if (evmChainId == BASE_CHAIN_ID) return WORMHOLE_EXECUTOR_BASE;
            if (evmChainId == ARBITRUM_CHAIN_ID) return WORMHOLE_EXECUTOR_ARBITRUM;
        }
        revert UnsupportedEvmChain(evmChainId);
    }

    /// @notice Validate that a Wormhole chain ID is supported
    /// @dev Max 3 comparisons (~45 gas) for 4 chains, reverts if unsupported
    function validateChainId(uint16 wormholeChainId) internal pure {
        if (wormholeChainId <= WORMHOLE_ARBITRUM) {
            if (wormholeChainId == WORMHOLE_ETHEREUM) return;
            if (wormholeChainId == WORMHOLE_ARBITRUM) return;
        } else {
            if (wormholeChainId == WORMHOLE_BASE) return;
            if (wormholeChainId == WORMHOLE_UNICHAIN) return;
        }
        revert UnsupportedWormholeChain(wormholeChainId);
    }
}
