//SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library WormholeMappings {
    /// @notice Convert EVM chain ID to Wormhole chain ID
    /// @dev Max 3 comparisons (~45 gas) for 4 chains
    function toWormholeId(uint256 evmChainId) internal pure returns (uint16) {
        if (evmChainId <= 130) {
            if (evmChainId == 1) return 2; // Ethereum
            if (evmChainId == 130) return 44; // Unichain
        } else {
            if (evmChainId == 8453) return 30; // Base
            if (evmChainId == 42161) return 23; // Arbitrum
        }
        revert("Unsupported chain");
    }

    /// @notice Convert Wormhole chain ID to EVM chain ID
    /// @dev Max 3 comparisons (~45 gas) for 4 chains
    function toEvmId(uint16 wormholeChainId) internal pure returns (uint256) {
        if (wormholeChainId <= 23) {
            if (wormholeChainId == 2) return 1; // Ethereum
            if (wormholeChainId == 23) return 42161; // Arbitrum
        } else {
            if (wormholeChainId == 30) return 8453; // Base
            if (wormholeChainId == 44) return 130; // Unichain
        }
        revert("Unsupported chain");
    }

    /// @notice Get Wormhole Core contract address by EVM chain ID
    /// @dev Max 3 comparisons (~45 gas) for 4 chains
    function getWormhole(uint256 evmChainId) internal pure returns (address) {
        if (evmChainId <= 130) {
            if (evmChainId == 1) return 0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B; // Ethereum
            if (evmChainId == 130) return 0xCa1D5a146B03f6303baF59e5AD5615ae0b9d146D; // Unichain
        } else {
            if (evmChainId == 8453) return 0xbebdb6C8ddC678FfA9f8748f85C815C556Dd8ac6; // Base
            if (evmChainId == 42161) return 0xa5f208e072434bC67592E4C49C1B991BA79BCA46; // Arbitrum
        }
        revert("Unsupported chain");
    }

    /// @notice Get Wormhole Relayer contract address by EVM chain ID
    /// @dev Max 3 comparisons (~45 gas) for 4 chains
    function getWormholeExecutor(uint256 evmChainId) internal pure returns (address) {
        if (evmChainId <= 130) {
            if (evmChainId == 1) return 0x84EEe8dBa37C36947397E1E11251cA9A06Fc6F8a; // Ethereum
            if (evmChainId == 130) return 0x764dD868eAdD27ce57BCB801E4ca4a193d231Aed; // Unichain
        } else {
            if (evmChainId == 8453) return 0x9E1936E91A4a5AE5A5F75fFc472D6cb8e93597ea; // Base
            if (evmChainId == 42161) return 0x3980f8318fc03d79033Bbb421A622CDF8d2Eeab4; // Arbitrum
        }
        revert("Unsupported chain");
    }
}
