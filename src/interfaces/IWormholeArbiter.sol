// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Lock} from "the-compact/src/types/EIP712Types.sol";
import {BatchSend, BatchPost, BatchClaimWithLocks, WormholeParams} from "../wormhole/WormholeTypes.sol";

/**
 * @title IWormholeArbiter
 * @notice Interface for the WormholeArbiter cross-chain claim relay system
 * @dev Relays fills from Tribunal on target chain to origin chain via Wormhole,
 *      then submits claim data to The Compact for settlement.
 */
interface IWormholeArbiter {
    // ======== Events ========

    /// @notice Emitted when a single claim is sent via executor (automatic delivery)
    /// @param chainId The destination chain ID
    /// @param claimHash The claim hash being relayed
    /// @param sequence The Wormhole sequence number for tracking
    event SingleSendEvent(uint256 indexed chainId, bytes32 indexed claimHash, uint64 indexed sequence);

    /// @notice Emitted when a single claim is posted via core (self-relay)
    /// @param chainId The destination chain ID
    /// @param claimHash The claim hash being relayed
    /// @param sequence The Wormhole sequence number for fetching VAA
    event SinglePostEvent(uint256 indexed chainId, bytes32 indexed claimHash, uint64 indexed sequence);

    /// @notice Emitted when a batch of claims is sent via executor
    /// @param chainId The destination chain ID
    /// @param claimHashes Array of claim hashes being relayed
    /// @param sequence The Wormhole sequence number for tracking
    event BatchSendEvent(uint256 indexed chainId, bytes32[] indexed claimHashes, uint64 indexed sequence);

    /// @notice Emitted when a batch of claim hashes is posted via core
    /// @param chainId The destination chain ID
    /// @param claimHashes Array of claim hashes being relayed
    /// @param sequence The Wormhole sequence number for fetching VAA
    event BatchPostEvent(uint256 indexed chainId, bytes32[] indexed claimHashes, uint64 indexed sequence);

    // ======== Custom Errors ========

    /// @notice Thrown when compact.arbiter doesn't match this contract
    error InvalidArbiter();

    /// @notice Thrown when context bytes is empty
    error ContextTooShort();

    /// @notice Thrown when encoded batch exceeds MAX_MESSAGE_SIZE
    error MessageExceedsMaxSize();

    /// @notice Thrown when batch contains more than 120 claims
    error TooManyClaims();

    /// @notice Thrown when claim hash not found in Tribunal.filled()
    error ClaimNotFilled();

    /// @notice Thrown when contract balance insufficient for Wormhole message fee
    error InsufficientFee();

    /// @notice Thrown when executor receives non-SEND message type
    error UnsupportedMessageType();

    /// @notice Thrown when VAA nonce doesn't match expected POST type
    error InvalidMessageType();

    /// @notice Thrown when provided claim data doesn't match claim hash in VAA
    error InvalidClaimHash();

    // ======== SEND Functions (Automatic Executor Delivery) ========

    /// @notice Sends a single claim via Wormhole executor for automatic delivery
    /// @param chainId The destination chain ID
    /// @param sponsor The address that authorized the original compact
    /// @param nonce The unique nonce for this compact
    /// @param expires The timestamp when this compact expires
    /// @param witness The witness hash (mandate hash) for EIP-712 validation
    /// @param commitments Array of Lock structs (lockTag, token, amount)
    /// @param allocatorData Optional allocator signature data
    /// @param sponsorSignature Sponsor's signature authorizing the claim
    /// @param params Wormhole delivery parameters (gasLimit, totalCost)
    /// @param signedQuote Signed executor quote for delivery cost verification
    /// @return sequence The Wormhole sequence number for tracking
    function send(
        uint256 chainId,
        address sponsor,
        uint256 nonce,
        uint256 expires,
        bytes32 witness,
        Lock[] calldata commitments,
        bytes calldata allocatorData,
        bytes calldata sponsorSignature,
        WormholeParams memory params,
        bytes calldata signedQuote
    ) external payable returns (uint64 sequence);

    /// @notice Sends a batch of claims to a single chain via Wormhole executor
    /// @param batch BatchSend struct containing claims, chain info, and delivery parameters
    /// @return sequence The Wormhole sequence number for tracking
    function batchSend(BatchSend calldata batch) external payable returns (uint64 sequence);

    /// @notice Sends multiple batches of claims to multiple chains via Wormhole executor
    /// @param batches Array of BatchSend structs, each targeting a different chain
    /// @return sequences Array of Wormhole sequence numbers, one per batch
    function multichainBatchSend(BatchSend[] calldata batches) external payable returns (uint64[] memory sequences);

    // ======== POST Functions (User Self-Relay) ========

    /// @notice Posts a single claim via Wormhole core for user self-relay
    /// @param chainId The destination chain ID
    /// @param sponsor The address that authorized the original compact
    /// @param nonce The unique nonce for this compact
    /// @param expires The timestamp when this compact expires
    /// @param witness The witness hash (mandate hash) for EIP-712 validation
    /// @param commitments Array of Lock structs (lockTag, token, amount)
    /// @param allocatorData Optional allocator signature data
    /// @param sponsorSignature Sponsor's signature authorizing the claim
    /// @return sequence The Wormhole sequence number for fetching the VAA
    function post(
        uint256 chainId,
        address sponsor,
        uint256 nonce,
        uint256 expires,
        bytes32 witness,
        Lock[] calldata commitments,
        bytes calldata allocatorData,
        bytes calldata sponsorSignature
    ) external payable returns (uint64 sequence);

    /// @notice Posts a batch of claim hashes via Wormhole core for user self-relay
    /// @dev Uses bitmap compression for up to 120 claims
    /// @param chainId The destination chain ID
    /// @param claimHashes Array of claim hashes to batch (max 120)
    /// @return sequence The Wormhole sequence number for fetching the VAA
    function batchPost(uint256 chainId, bytes32[] calldata claimHashes) external payable returns (uint64 sequence);

    /// @notice Posts multiple batches of claim hashes to multiple chains via Wormhole core
    /// @param batches Array of BatchPost structs, each containing chainId and claimHashes
    /// @return sequences Array of Wormhole sequence numbers, one per batch
    function multichainBatchPost(BatchPost[] calldata batches) external payable returns (uint64[] memory sequences);

    // ======== RECEIVE Functions (Destination Chain) ========

    /// @notice Receives and processes a single POST message relayed by user via VAA
    /// @param encodedVaa The encoded Wormhole VAA fetched by the user
    function receivePost(bytes calldata encodedVaa) external;

    /// @notice Batch receives multiple POST messages (NOT IMPLEMENTED)
    /// @param encodedVAs Array of encoded Wormhole VAAs
    function receivePosts(bytes[] calldata encodedVAs) external;

    /// @notice Receives and processes a batch POST message relayed by user via VAA
    /// @dev VAA contains only claim hashes + claimants + scaling factors (bitmap-compressed).
    ///      Caller provides full claim data which is validated against claim hashes in VAA
    /// @param encodedVaa The encoded Wormhole VAA fetched by the user
    /// @param claims Array of full claim data (must match claim hashes in VAA payload)
    function receiveBatchPost(bytes calldata encodedVaa, BatchClaimWithLocks[] calldata claims) external;

    // ======== Helper Functions (Context Encoding) ========

    /// @notice Encodes context data for SEND operations via Tribunal dispatchCallback
    /// @dev Sets FLAG_IS_SEND (0x04) to route through send path
    /// @param allocatorData Optional allocator signature data
    /// @param sponsorSignature Sponsor's signature authorizing the claim
    /// @param params Wormhole delivery parameters (gasLimit, totalCost)
    /// @param signedQuote Signed executor quote for delivery cost verification
    /// @return Encoded context bytes for dispatchCallback
    function encodeSendContext(
        bytes calldata allocatorData,
        bytes calldata sponsorSignature,
        WormholeParams memory params,
        bytes calldata signedQuote
    ) external pure returns (bytes memory);

    /// @notice Encodes context data for POST operations via Tribunal dispatchCallback
    /// @dev Excludes FLAG_IS_SEND to route through post path
    /// @param allocatorData Optional allocator signature data
    /// @param sponsorSignature Sponsor's signature authorizing the claim
    /// @return Encoded context bytes for dispatchCallback
    function encodePostContext(bytes calldata allocatorData, bytes calldata sponsorSignature)
        external
        pure
        returns (bytes memory);
}
