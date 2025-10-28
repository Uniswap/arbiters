// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BatchCompact} from "the-compact/src/types/EIP712Types.sol";

/**
 * @notice Contains all data needed to process a claim
 * @dev This struct packages together the compact, signatures, and claim details
 */
struct SendData {
    BatchCompact compact;
    bytes sponsorSignature;
    bytes allocatorSignature;
    bytes32 mandateHash;
    bytes32 claimant;
    uint256[] claimAmounts;
}
