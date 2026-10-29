// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BatchCompact} from "the-compact/src/types/EIP712Types.sol";

/**
 * @title TribunalMock
 * @notice Mock implementation of ITribunal for testing BaseArbiter
 * @dev Only implements filled() and claimReductionScalingFactor() properly for testing
 */
contract TribunalMock {
    // Mapping from claim hash to claimant
    mapping(bytes32 => bytes32) private _filled;

    // Mapping from claim hash to claim reduction scaling factor
    mapping(bytes32 => uint256) private _claimReductionScalingFactor;

    /**
     * @notice Set the filled status for a claim hash
     * @param claimHash The claim hash
     * @param claimant The claimant (0 if not filled)
     */
    function setFilled(bytes32 claimHash, bytes32 claimant) external {
        _filled[claimHash] = claimant;
    }

    /**
     * @notice Set the claim reduction scaling factor for a claim hash
     * @param claimHash The claim hash
     * @param scalingFactor The scaling factor (defaults to 1e18 if not set)
     */
    function setClaimReductionScalingFactor(bytes32 claimHash, uint256 scalingFactor) external {
        _claimReductionScalingFactor[claimHash] = scalingFactor;
    }

    // ======== ITribunal Implementation ========

    function filled(bytes32 claimHash) external view returns (bytes32) {
        return _filled[claimHash];
    }

    function claimReductionScalingFactor(bytes32 claimHash) external view returns (uint256) {
        uint256 storedFactor = _claimReductionScalingFactor[claimHash];
        // Match real Tribunal behavior:
        // - type(uint256).max (cancelled) → return 0
        // - 0 (not set) → return 1e18 (default)
        // - other value → return that value
        if (storedFactor == type(uint256).max) {
            return 0; // Cancelled claim
        }
        return storedFactor == 0 ? 1e18 : storedFactor;
    }

    /**
     * @notice Mock implementation of dispatchCallback for testing
     * @dev Forwards the call to the arbiter (compact.arbiter) with the provided context
     * @return The selector of dispatchCallback to confirm successful execution
     */
    function dispatchCallback(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes32 mandateHash,
        bytes32 claimHash,
        bytes32 claimant,
        uint256 scalingFactor,
        uint256[] calldata claimAmounts,
        bytes calldata context
    ) external payable returns (bytes4) {
        // Forward the call to the arbiter
        (bool success, bytes memory returnData) = compact.arbiter
        .call{
            value: msg.value
        }(
            abi.encodeWithSignature(
                "dispatchCallback(uint256,(address,address,uint256,uint256,(bytes12,address,uint256)[]),bytes32,bytes32,bytes32,uint256,uint256[],bytes)",
                chainId,
                compact,
                mandateHash,
                claimHash,
                claimant,
                scalingFactor,
                claimAmounts,
                context
            )
        );

        require(success, "dispatchCallback call failed");

        // Return the selector from the arbiter's response
        return abi.decode(returnData, (bytes4));
    }
}
