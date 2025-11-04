// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

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
        uint256 factor = _claimReductionScalingFactor[claimHash];
        return factor == 0 ? 1e18 : factor; // Default to 1e18 if not set
    }
}
