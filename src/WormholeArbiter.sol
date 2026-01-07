// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BatchClaim} from "lib/the-compact/src/types/BatchClaims.sol";
import {BatchClaimComponent, Component} from "the-compact/src/types/Components.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";
import {WITNESS_TYPESTRING} from "tribunal/types/TribunalTypeHashes.sol";
import {IDispatchCallback} from "tribunal/interfaces/IDispatchCallback.sol";
import {ExecutorSendReceive} from "./wormhole/WormholeExecutor.sol";
import {CoreBridgeLib} from "wormhole-sdk/libraries/CoreBridge.sol";
import {WormholeMappings} from "./wormhole/WormholeMappings.sol";
import {Message} from "./libraries/Message.sol";
import {
    MessagePackingType,
    BatchPost,
    BatchSend,
    BatchClaimWithLocks,
    WormholeParams
} from "./wormhole/WormholeTypes.sol";
import {BaseArbiter} from "./abstracts/BaseArbiter.sol";

/**
 * @notice Cross-chain arbiter for The Compact using Wormhole infrastructure
 * @dev Implements bidirectional message flow between fill chains and claim chains
 */

contract WormholeArbiter is ExecutorSendReceive, IDispatchCallback, BaseArbiter {
    using Message for bytes;

    uint8 constant CONSISTENCY_LEVEL = 201; // safe for now. maybe custom in the future
    uint16 constant MAX_MESSAGE_SIZE = 5_000; // 5KB -- solana can only do 1232 bytes so maybe need to reduce

    event SingleSendEvent(uint256 indexed chainId, bytes32 indexed claimHash, uint64 indexed sequence);
    event SinglePostEvent(uint256 indexed chainId, bytes32 indexed claimHash, uint64 indexed sequence);
    event BatchSendEvent(uint256 indexed chainId, bytes32[] indexed claimHashes, uint64 indexed sequence);
    event BatchPostEvent(uint256 indexed chainId, bytes32[] indexed claimHashes, uint64 indexed sequence);

    constructor()
        ExecutorSendReceive(
            WormholeMappings.getWormhole(block.chainid),
            WormholeMappings.getWormholeExecutor(block.chainid)
            // need to check other types of witnesses here too
        )
    {
        // TODO enforce checks on tribunal in deployment maybe?
    }

    // ============================================================================
    // DISPATCH CALLBACK: Tribunal entrypoint and context encoding / decoding
    // ============================================================================

    /**
     * @notice Callback function invoked by Tribunal after a fill is completed on the fill chain
     * @dev Routes to either SEND (automatic relay) or POST (self-relay) based on context flags.
     *
     * @param chainId The destination chain ID where the resource lock exists and claim should be submitted
     * @param compact The batch compact data containing sponsor info, nonce, expiry, and commitments (locks)
     * @param mandateHash The witness hash used for EIP-712 claim validation
     * @param claimHash The claim hash that can be claimed after performing the fill
     * @param claimant The bytes32 claimant identifier (lock tag ++ address) returned by Tribunal
     * @param claimReductionScalingFactor Scaling factor applied to claim amounts (1e18 = 100%, 0 = cancelled)
     * @param context Encoded operation context containing:
     *                - First byte: flags (0x04 = SEND operation, 0x00 = POST operation)
     *                - For SEND: allocator data, sponsor signature, Wormhole params, and signed executor quote
     *                - For POST: allocator data and sponsor signature only
     *
     * @return Function selector to confirm successful execution to Tribunal
     */
    function dispatchCallback(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes32 mandateHash,
        bytes32 claimHash,
        bytes32 claimant,
        uint256 claimReductionScalingFactor,
        uint256[] calldata,
        /*claimAmounts*/
        bytes calldata context
    ) external payable refundExcessEth returns (bytes4) {
        require(compact.arbiter == address(this), "Invalid arbiter");
        require(context.length >= 1, "Context too short");

        uint8 flags;
        assembly {
            flags := byte(0, calldataload(context.offset))
        }

        bytes calldata allocatorData;
        bytes calldata sponsorSignature;

        if ((flags & 0x04) != 0) {
            WormholeParams memory wormholeParams;
            bytes calldata signedQuote;

            (allocatorData, sponsorSignature, wormholeParams, signedQuote) = Message.decodeSendContext(context);

            bytes memory message = Message.encode(
                compact.sponsor,
                compact.nonce,
                compact.expires,
                mandateHash,
                compact.commitments,
                allocatorData,
                sponsorSignature,
                claimant,
                claimReductionScalingFactor
            );

            uint64 sequence = _sendMessage(
                message,
                wormholeParams.totalCost,
                chainId,
                signedQuote,
                wormholeParams.gasLimit,
                uint32(MessagePackingType.SINGLE_SEND)
            );

            emit SingleSendEvent(chainId, claimHash, sequence); // placing here so we don't have to pass claimHash because stack to deep
        } else {
            (allocatorData, sponsorSignature) = Message.decodePostContext(context);

            bytes memory message = Message.encode(
                compact.sponsor,
                compact.nonce,
                compact.expires,
                mandateHash,
                compact.commitments,
                allocatorData,
                sponsorSignature,
                claimant,
                claimReductionScalingFactor
            );
            uint64 sequence = _postMessage(uint32(MessagePackingType.SINGLE_POST), message);

            emit SinglePostEvent(chainId, claimHash, sequence);
        }

        return IDispatchCallback.dispatchCallback.selector;
    }

    /**
     * @notice Encodes context data for SEND operations (automatic executor delivery)
     * @dev Sets FLAG_IS_SEND (0x04) flag to route through send path in dispatchCallback
     * @param allocatorData Optional allocator signature data
     * @param sponsorSignature Sponsor's signature authorizing the claim
     * @param params Wormhole delivery parameters (gasLimit, totalCost)
     * @param signedQuote Signed executor quote for delivery cost verification
     * @return Encoded context bytes for dispatchCallback
     */
    function encodeSendContext(
        bytes calldata allocatorData,
        bytes calldata sponsorSignature,
        WormholeParams memory params,
        bytes calldata signedQuote
    ) external pure returns (bytes memory) {
        return Message.encodeSendContext(allocatorData, sponsorSignature, params, signedQuote);
    }

    /**
     * @notice Encodes context data for POST operations (filler self-relay)
     * @dev Excludes FLAG_IS_SEND (0x04) to route through post path in dispatchCallback
     * @param allocatorData Optional allocator signature data
     * @param sponsorSignature Sponsor's signature authorizing the claim
     * @return Encoded context bytes for dispatchCallback
     */
    function encodePostContext(bytes calldata allocatorData, bytes calldata sponsorSignature)
        external
        pure
        returns (bytes memory)
    {
        return Message.encodePostContext(allocatorData, sponsorSignature);
    }

    // ============================================================================
    // SEND OPERATIONS: Automatic Relayed Delivery (via Wormhole Executor)
    // ============================================================================

    /**
     * @notice Sends a message via Wormhole executor for automatic delivery
     * @dev Wraps _publishAndRelay with hardcoded CONSISTENCY_LEVEL and refund address
     * @param payload The encoded message payload to transmit
     * @param totalCost The total delivery cost (execution cost + Wormhole message fee)
     * @param chainId The destination EVM chain ID
     * @param signedQuote Signed executor quote for delivery cost verification
     * @param gasLimit Gas limit for execution on destination chain
     * @param nonce Message type identifier (MessagePackingType enum)
     * @return sequence The Wormhole sequence number for tracking
     */
    function _sendMessage(
        bytes memory payload,
        uint256 totalCost,
        uint256 chainId,
        bytes calldata signedQuote,
        uint128 gasLimit,
        uint32 nonce
    ) internal returns (uint64 sequence) {
        sequence = _publishAndRelay(
            payload,
            CONSISTENCY_LEVEL,
            totalCost,
            WormholeMappings.toWormholeId(chainId),
            msg.sender, // TODO: change send context to include refund address
            signedQuote,
            gasLimit,
            0,
            nonce,
            ""
        );
    }

    /**
     * @notice Sends a single claim via Wormhole with automatic executor delivery
     * @dev Validates claim with Tribunal, encodes it, and transmits via Wormhole executor
     * @param chainId The destination chain ID
     * @param sponsor The address that authorized the original compact
     * @param nonce The unique nonce for this compact
     * @param expires The timestamp when this compact expires
     * @param witness The witness hash (mandate hash) for EIP-712 validation
     * @param commitments Array of Lock structs (lockTag, token, amount)
     * @param allocatorData Optional allocator signature data
     * @param sponsorSignature Sponsor's signature authorizing the claim
     * @param params Wormhole delivery parameters (gasLimit, totalCost)
     * @param signedQuote Signed executor quote for delivery cost verification
     * @return sequence The Wormhole sequence number for tracking
     */
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
    ) external payable virtual refundExcessEth returns (uint64 sequence) {
        (bytes32 claimHash, bytes32 claimant, uint256 claimReductionScalingFactor) =
            _validateBatchClaim(sponsor, nonce, expires, witness, commitments);

        bytes memory message = Message.encode(
            sponsor,
            nonce,
            expires,
            witness,
            commitments,
            allocatorData,
            sponsorSignature,
            claimant,
            claimReductionScalingFactor
        );

        sequence = _sendMessage(
            message, params.totalCost, chainId, signedQuote, params.gasLimit, uint32(MessagePackingType.SINGLE_SEND)
        );

        emit SingleSendEvent(chainId, claimHash, sequence);
    }

    /**
     * @notice Internal function to send a batch of claims to a single chain via executor (BATCH_SEND)
     * @dev Validates claims, encodes batch, enforces MAX_MESSAGE_SIZE, transmits via _sendMessage
     * @param batch BatchSend struct containing chainId, claims, gasLimit, totalCost, signedQuote
     * @return sequence The Wormhole sequence number for tracking
     */
    function _batchSend(BatchSend calldata batch) internal virtual returns (uint64 sequence) {
        bytes32[] memory claimHash = new bytes32[](batch.claims.length);
        bytes32[] memory claimant = new bytes32[](batch.claims.length);
        uint256[] memory claimReductionScalingFactor = new uint256[](batch.claims.length);

        for (uint256 i = 0; i < batch.claims.length; ++i) {
            (claimHash[i], claimant[i], claimReductionScalingFactor[i]) = _validateBatchClaim(
                batch.claims[i].sponsor,
                batch.claims[i].nonce,
                batch.claims[i].expires,
                batch.claims[i].witness,
                batch.claims[i].commitments
            );
        }

        bytes memory encodedBatch = Message.encodeBatchSend(claimant, claimReductionScalingFactor, batch.claims);

        require(encodedBatch.length <= MAX_MESSAGE_SIZE, "Message exceeds max size");

        sequence = _sendMessage(
            encodedBatch,
            batch.totalCost,
            batch.chainId,
            batch.signedQuote,
            batch.gasLimit,
            uint32(MessagePackingType.BATCH_SEND)
        );

        emit BatchSendEvent(batch.chainId, claimHash, sequence);
    }

    /**
     * @notice Sends a batch of claims to a single chain via Wormhole executor
     * @dev Public entry point for BATCH_SEND. Calls _batchSend() and refunds excess ETH
     * @param batch BatchSend struct containing claims, chain info, and delivery parameters
     * @return sequence The Wormhole sequence number for tracking
     */
    function batchSend(BatchSend calldata batch) external payable virtual refundExcessEth returns (uint64 sequence) {
        return _batchSend(batch);
    }

    /**
     * @notice Sends multiple batches of claims to multiple chains via Wormhole executor
     * @dev Loops through batches calling _batchSend() for each. Refunds excess ETH once at end
     * @param batches Array of BatchSend structs, each targeting a different chain
     * @return sequences Array of Wormhole sequence numbers, one per batch
     */
    function multichainBatchSend(BatchSend[] calldata batches)
        external
        payable
        virtual
        refundExcessEth
        returns (uint64[] memory sequences)
    {
        sequences = new uint64[](batches.length);
        unchecked {
            for (uint256 i = 0; i < batches.length; ++i) {
                sequences[i] = _batchSend(batches[i]);
            }
        }
    }

    // ============================================================================
    // POST OPERATIONS: User Self-Relayed Delivery (via Wormhole Core)
    // ============================================================================

    /**
     * @notice Publishes a message via Wormhole core contract for user self-relay
     * @dev Wraps _coreBridge.publishMessage() to emit a VAA for self relay
     * @param nonce Message type identifier (MessagePackingType enum)
     * @param payload The encoded message payload to publish
     * @return sequence The Wormhole sequence number for fetching the VAA
     */
    function _postMessage(uint32 nonce, bytes memory payload) internal virtual returns (uint64 sequence) {
        uint256 fee = _coreBridge.messageFee();
        require(address(this).balance >= fee, "Insufficient ETH for wormhole fee");
        sequence = _coreBridge.publishMessage{value: fee}(nonce, payload, CONSISTENCY_LEVEL);
    }

    /**
     * @notice Publishes a single claim via Wormhole core for user self-relay
     * @dev Validates claim with Tribunal, encodes it, publishes to Wormhole core
     * @param chainId The destination chain ID
     * @param sponsor The address that authorized the original compact
     * @param nonce The unique nonce for this compact
     * @param expires The timestamp when this compact expires
     * @param witness The witness hash (mandate hash) for EIP-712 validation
     * @param commitments Array of Lock structs (lockTag, token, amount)
     * @param allocatorData Optional allocator signature data
     * @param sponsorSignature Sponsor's signature authorizing the claim
     * @return sequence The Wormhole sequence number for fetching the VAA
     */
    function post(
        uint256 chainId,
        address sponsor,
        uint256 nonce,
        uint256 expires,
        bytes32 witness,
        Lock[] calldata commitments,
        bytes calldata allocatorData,
        bytes calldata sponsorSignature
    ) external payable virtual refundExcessEth returns (uint64 sequence) {
        (bytes32 claimHash, bytes32 claimant, uint256 claimReductionScalingFactor) =
            _validateBatchClaim(sponsor, nonce, expires, witness, commitments);

        bytes memory message = Message.encode(
            sponsor,
            nonce,
            expires,
            witness,
            commitments,
            allocatorData,
            sponsorSignature,
            claimant,
            claimReductionScalingFactor
        );
        sequence = _postMessage(uint32(MessagePackingType.SINGLE_POST), message);

        emit SinglePostEvent(chainId, claimHash, sequence);
    }

    /**
     * @notice Publishes a batch of claim hashes via Wormhole core for user self-relay
     * @dev Uses bitmap compression for up to 120 claims. More efficient than multiple single posts
     * @param chainId The destination chain ID
     * @param claimHashes Array of claim hashes to batch (max 120)
     * @return sequence The Wormhole sequence number for fetching the VAA
     */
    function batchPost(uint256 chainId, bytes32[] calldata claimHashes)
        public
        payable
        virtual
        refundExcessEth
        returns (uint64 sequence)
    {
        sequence = _batchPost(chainId, claimHashes);
    }

    /**
     * @notice Internal function to publish a batch of claim hashes without refund logic
     * @dev Validates claims, encodes with bitmap compression, publishes to Wormhole core
     * @param chainId The destination chain ID (for event emission)
     * @param claimHashes Array of claim hashes to batch (max 120)
     * @return sequence The Wormhole sequence number for fetching the VAA
     */
    function _batchPost(uint256 chainId, bytes32[] calldata claimHashes) internal virtual returns (uint64 sequence) {
        require(claimHashes.length <= 120, "Max 120 claims per batch");

        bytes32[] memory claimants = new bytes32[](claimHashes.length);
        uint256[] memory scalingFactors = new uint256[](claimHashes.length);

        for (uint256 i = 0; i < claimHashes.length; i++) {
            claimants[i] = TRIBUNAL.filled(claimHashes[i]);
            require(claimants[i] != bytes32(0), "Claim not filled in Tribunal");
            scalingFactors[i] = TRIBUNAL.claimReductionScalingFactor(claimHashes[i]);
        }

        bytes memory encodedBatch = Message.encodeBatchPost(claimants, claimHashes, scalingFactors);

        sequence = _postMessage(uint32(MessagePackingType.BATCH_POST), encodedBatch);

        emit BatchPostEvent(chainId, claimHashes, sequence);
    }

    /**
     * @notice Publishes multiple batches of claim hashes to multiple chains via Wormhole core
     * @dev Loops through batches calling _batchPost() for each. Refunds excess ETH once at end
     * @param batches Array of BatchPost structs, each containing chainId and claimHashes
     * @return sequences Array of Wormhole sequence numbers, one per batch
     */
    function multichainBatchPost(BatchPost[] calldata batches)
        public
        payable
        virtual
        refundExcessEth
        returns (uint64[] memory sequences)
    {
        sequences = new uint64[](batches.length);
        unchecked {
            for (uint256 i = 0; i < batches.length; ++i) {
                BatchPost calldata batch = batches[i];
                sequences[i] = _batchPost(batch.chainId, batch.claimHashes);
            }
        }
    }

    // ============================================================================
    // RECEIVE OPERATIONS: Relayer Delivery
    // ============================================================================

    /**
     * @notice Receives and processes SEND messages delivered by Wormhole executor
     * @dev Overrides ExecutorReceiveImpl._executeVaa(). Validates chain ID and emitter address
     * @param payload The encoded claim or batch of claims
     * @param nonce Message type identifier (SINGLE_SEND or BATCH_SEND)
     * @param peerChain The Wormhole chain ID of the source chain
     * @param emitterAddress The address that sent the message (must match this contract)
     */
    function _executeVaa(
        bytes calldata payload,
        uint32, // timestamp - unused
        uint32 nonce,
        uint16 peerChain,
        bytes32 emitterAddress,
        uint64, // sequence - unused
        uint8 // consistencyLevel - unused
    ) internal override {
        MessagePackingType messageType = MessagePackingType(nonce);

        // Validate chain ID to prevent messages from unsupported/compromised chains
        // Even though emitterAddress is validated via CREATE2, a compromised chain
        // could arbitrarily set storage slots to bypass immutability rules
        WormholeMappings.validateChainId(peerChain);

        _validateMessageSender(address(uint160(uint256(emitterAddress))));

        if (messageType == MessagePackingType.SINGLE_SEND) {
            _sendClaim(Message.decode(payload));
        } else if (messageType == MessagePackingType.BATCH_SEND) {
            _processBatchSend(payload);
        } else {
            revert("Unsupported message type for executor delivery");
        }
    }

    /**
     * @notice Internal helper to process BATCH_SEND messages
     * @dev Decodes batch using Message.decodeBatchSend() and submits each claim to The Compact.
     *
     * @param payload The encoded batch of claims with claimants and scaling factors
     */
    function _processBatchSend(bytes calldata payload) internal virtual {
        BatchClaim[] memory claims = Message.decodeBatchSend(payload);
        unchecked {
            for (uint256 i = 0; i < claims.length; ++i) {
                _sendClaim(claims[i]);
            }
        }
    }

    // ============================================================================
    // RECEIVE OPERATIONS: User Self-Relayed Delivery (via Wormhole Core)
    // ============================================================================

    /**
     * @notice Receives and processes a single POST message relayed by user via VAA
     * @dev Validates VAA via _parseAndValidateVaa(), then decodes and processes the claim
     * @param encodedVaa The encoded Wormhole VAA fetched by the user
     */
    function receivePost(bytes calldata encodedVaa) external virtual {
        bytes calldata payload = _parseAndValidateVaa(encodedVaa, MessagePackingType.SINGLE_POST);
        _sendClaim(Message.decode(payload));
    }

    /**
     * @notice Batch receives multiple POST messages (NOT IMPLEMENTED)
     * @dev TODO: Implement per the efficiency logic in lib/wormhole-solidity-sdk/src/libraries/CoreBridge.sol
     *      This would allow users to submit multiple VAAs in a single transaction for gas efficiency.
     *
     * @param encodedVAs Array of encoded Wormhole VAAs
     */
    function receivePosts(bytes[] calldata encodedVAs) external virtual {}

    /**
     * @notice Receives and processes a batch POST message relayed by user via VAA
     * @dev VAA contains only claim hashes + claimants + scaling factors (bitmap-compressed).
     *      Caller provides full claim data which is validated against claim hashes in VAA
     * @param encodedVaa The encoded Wormhole VAA fetched by the user
     * @param claims Array of full claim data (must match claim hashes in VAA payload)
     */
    function receiveBatchPost(bytes calldata encodedVaa, BatchClaimWithLocks[] calldata claims) external virtual {
        bytes calldata payload = _parseAndValidateVaa(encodedVaa, MessagePackingType.BATCH_POST);
        (bytes32[] memory claimants, bytes32[] memory claimHashes, uint256[] memory scalingFactors) =
            Message.decodeBatchPost(payload);

        for (uint256 i = 0; i < claimants.length; i++) {
            // Validate that the provided claimHash matches the derived claimHash
            require(
                _deriveClaimHash(
                    claims[i].sponsor, claims[i].nonce, claims[i].expires, claims[i].witness, claims[i].commitments
                ) == claimHashes[i],
                "Invalid claim hash"
            );

            // Transform commitments into BatchClaimComponents using scalingFactors and claimants
            Lock[] calldata commitments = claims[i].commitments;
            BatchClaimComponent[] memory batchClaimComponents = new BatchClaimComponent[](commitments.length);

            unchecked {
                for (uint256 j = 0; j < commitments.length; ++j) {
                    Lock calldata lock = commitments[j];

                    // Pack lockTag + token into id
                    uint256 id = uint256(bytes32(lock.lockTag)) | uint256(uint160(lock.token));

                    // Create Component portions based on scaling factor
                    Component[] memory portions;
                    if (scalingFactors[i] == 0) {
                        // Empty portions array for cancelled claims (zero scaling factor)
                        portions = new Component[](0);
                    } else {
                        // Calculate scaled amount
                        uint256 scaledAmount =
                            scalingFactors[i] == 1e18 ? lock.amount : (lock.amount * scalingFactors[i]) / 1e18;

                        // Create single Component portion
                        portions = new Component[](1);
                        portions[0] = Component({claimant: uint256(claimants[i]), amount: scaledAmount});
                    }

                    // Create BatchClaimComponent
                    batchClaimComponents[j] =
                        BatchClaimComponent({id: id, allocatedAmount: lock.amount, portions: portions});
                }
            }

            BatchClaim memory claim = BatchClaim({
                allocatorData: claims[i].allocatorData,
                sponsorSignature: claims[i].sponsorSignature,
                sponsor: claims[i].sponsor,
                nonce: claims[i].nonce,
                expires: claims[i].expires,
                witness: claims[i].witness,
                witnessTypestring: WITNESS_TYPESTRING,
                claims: batchClaimComponents
            });

            _sendClaim(claim);
        }
    }

    /**
     * @notice Parses and validates a Wormhole VAA for POST operations
     * @dev Verifies VAA via CoreBridgeLib, validates chain ID, emitter address, and message type
     * @param encodedVaa The encoded Wormhole VAA fetched by the user
     * @param expectedType The expected MessagePackingType (SINGLE_POST or BATCH_POST)
     * @return payload The decoded message payload containing claim data
     */
    function _parseAndValidateVaa(bytes calldata encodedVaa, MessagePackingType expectedType)
        internal
        view
        returns (bytes calldata)
    {
        (, // timestamp (unused)
            uint32 nonce,
            uint16 emitterChainId,
            bytes32 emitterAddress,, // sequence (unused)
            , // consistencyLevel (unused)
            bytes calldata payload
        ) = CoreBridgeLib.decodeAndVerifyVaaCd(address(_coreBridge), encodedVaa);

        // Validate chain ID to prevent messages from unsupported/compromised chains
        // Even though emitterAddress is validated via CREATE2, a compromised chain
        // could arbitrarily set storage slots to bypass immutability rules
        WormholeMappings.validateChainId(emitterChainId);

        _validateMessageSender(address(uint160(uint256(emitterAddress))));

        require(MessagePackingType(nonce) == expectedType, "Invalid message type");

        return payload;
    }
}
