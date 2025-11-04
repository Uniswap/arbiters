// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BatchClaim} from "lib/the-compact/src/types/BatchClaims.sol";
import {BatchClaimComponent, Component} from "the-compact/src/types/Components.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";
import {WITNESS_TYPESTRING} from "tribunal/types/TribunalTypeHashes.sol";
import {ExecutorSendReceive} from "./wormhole/WormholeExecutor.sol";
import {CoreBridgeLib} from "wormhole-sdk/libraries/CoreBridge.sol";
import {WormholeMappings} from "./wormhole/WormholeMappings.sol";
import {Message} from "./libraries/Message.sol";
import {MessagePackingType, BatchPost, BatchSend, BatchClaimWithLocks, WormholeParams} from "./wormhole/WormholeTypes.sol";
import {BaseArbiter} from "./abstracts/BaseArbiter.sol";

/**
 * @notice Cross-chain arbiter for The Compact using Wormhole infrastructure
 * @dev Implements bidirectional message flow between fill chains and claim chains
 */

interface IDispatchCallback {
    /**
     * @notice Callback function to be called by the Tribunal contract after a fill is completed.
     * @return This function selector to confirm successful execution.
     */
    function dispatchCallback(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes32 mandateHash,
        bytes32 claimHash,
        bytes32 claimant,
        uint256 claimReductionScalingFactor,
        uint256[] calldata claimAmounts,
        bytes calldata context
    ) external payable returns (bytes4);
}

contract WormholeArbiter is ExecutorSendReceive, IDispatchCallback, BaseArbiter {
    using Message for bytes;

    uint8 constant CONSISTENCY_LEVEL = 201; // safe for now. maybe custom in the future
    uint16 constant MAX_MESSAGE_SIZE = 5_000; // 5KB -- solana can only do 1232 bytes so maybe need to reduce

    bytes4 constant DISPATCH_CALLBACK_SELECTOR =
        bytes4(keccak256("dispatchCallback(bytes32,bytes32,bytes32,bytes32,uint256,uint256[],bytes)"));

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
        // check that tribunal witness typestring matches WITNESS_TYPESTRING and other checks here too
        (string memory witnessTypestring,) = TRIBUNAL.getCompactWitnessDetails();
        require(
            keccak256(bytes(WITNESS_TYPESTRING)) == keccak256(bytes(witnessTypestring)),
            "Tribunal witness typestring mismatch"
        );
    }

    // ============================================================================
    // DISPATCH CALLBACK: Tribunal entrypoint and context encoding / decoding
    // ============================================================================

    function dispatchCallback(
        uint256 chainId, //chainId where the resource lock lives
        BatchCompact calldata compact, //sponsor, nonce, expires, (lock tag ++ address ++ amount)
        bytes32 mandateHash, //witness
        bytes32 claimHash,
        bytes32 claimant, //claimant
        uint256 claimReductionScalingFactor, //claimReductionScalingFactor
        uint256[] calldata claimAmounts, //claimAmounts per portion
        bytes calldata context //allocator data, sponsor signature, claims
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

            uint64 sequence = _send(
                chainId,
                compact.sponsor,
                compact.nonce,
                compact.expires,
                mandateHash,
                compact.commitments,
                allocatorData,
                sponsorSignature,
                claimant,
                claimReductionScalingFactor,
                wormholeParams,
                signedQuote
            );

            emit SingleSendEvent(chainId, claimHash, sequence); // placing here so we don't have to pass claimHash because stack to deep

        } else {
            (allocatorData, sponsorSignature) = Message.decodePostContext(context);
            _post(
                chainId,
                compact.sponsor,
                compact.nonce,
                compact.expires,
                mandateHash,
                compact.commitments,
                allocatorData,
                sponsorSignature,
                claimHash,
                claimant,
                claimReductionScalingFactor
            );
        }

        return DISPATCH_CALLBACK_SELECTOR;
    }

    function encodeSendContext(
        bytes calldata allocatorData,
        bytes calldata sponsorSignature,
        WormholeParams memory params,
        bytes calldata signedQuote
    ) internal pure returns (bytes memory) {
        return Message.encodeSendContext(allocatorData, sponsorSignature, params, signedQuote);
    }

    function encodePostContext(bytes calldata allocatorData, bytes calldata sponsorSignature)
        internal
        pure
        returns (bytes memory)
    {
        return Message.encodePostContext(allocatorData, sponsorSignature);
    }

    // ============================================================================
    // SEND OPERATIONS: Automatic Relayed Delivery (via Wormhole Relayer)
    // ============================================================================

    /**
     * @notice Sends a message via Wormhole relayer for automatic delivery
     * @dev Handles fee calculation, balance validation, and relayer invocation
     * @dev Used for SEND operations with automatic cross-chain delivery
     */
    function _sendMessage(
        bytes memory payload,
        uint256 totalCost, //must equal execution cost + Wormhole message fee for publishing!
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
            msg.sender, // tribunal refunds excess ETH to msg.sender (will chain refund to msg.sender)
            signedQuote,
            gasLimit,
            0,
            nonce,
            ""
        );
    }

    /**
     * @notice Sends a single message via Wormhole relayer with automatic delivery (SINGLE_SEND)
     * @dev Sends via wormholeRelayer.sendPayloadToEvm() for automatic cross-chain delivery
     * @dev Constructs BatchClaimComponent[] from Lock[] + portion data for message encoding
     */
    function _send(
        uint256 chainId,
        address sponsor,
        uint256 nonce,
        uint256 expires,
        bytes32 witness,
        Lock[] calldata commitments, //lock tag ++ address ++ amount
        bytes calldata allocatorData,
        bytes calldata sponsorSignature,
        bytes32 claimant,
        uint256 claimReductionScalingFactor,
        WormholeParams memory params,
        bytes calldata signedQuote
    ) internal returns (uint64 sequence) {
        // need to fix for locks type
        bytes memory message = Message.encode(sponsor, nonce, expires, witness, commitments, allocatorData, sponsorSignature, claimant, claimReductionScalingFactor);

        sequence =
            _sendMessage(message, params.totalCost, chainId, signedQuote, params.gasLimit, uint32(MessagePackingType.SINGLE_SEND));
    }

    function send(
        uint256 chainId,
        address sponsor,
        uint256 nonce,
        uint256 expires,
        bytes32 witness,
        Lock[] calldata commitments, //lock tag ++ address ++ amount
        bytes calldata allocatorData,
        bytes calldata sponsorSignature,
        WormholeParams memory params,
        bytes calldata signedQuote
    ) external payable virtual refundExcessEth returns (uint64 sequence) {

        (bytes32 claimHash, bytes32 claimant, uint256 claimReductionScalingFactor) =
            _validateBatchClaim(sponsor, nonce, expires, witness, commitments);

        sequence = _send(
            chainId,
            sponsor,
            nonce,
            expires,
            witness,
            commitments,
            allocatorData,
            sponsorSignature,
            claimant,
            claimReductionScalingFactor,
            params,
            signedQuote
        );

        emit SingleSendEvent(chainId, claimHash, sequence);
    }

    /**
     * @notice Internal function to send a batch of full messages without refund logic
     * @dev Used by both batchSend and batchMultichainSend to avoid duplicate refunds
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
     * @notice Sends a batch of full message data to a single chain via relayer (BATCH_SEND)
     * @dev Public entry point - calls _batchSend() then refunds excess ETH
     */
    function batchSend(BatchSend calldata batch) public payable virtual refundExcessEth returns (uint64 sequence) {
        return _batchSend(batch);
    }

    /**
     * @notice Sends batches of full message data to multiple chains via relayer (multichain BATCH_SEND)
     * @dev Loops through chains calling _batchSend(), refunds once at the end
     */
    function multichainBatchSend(BatchSend[] calldata batches)
        public
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
     * @dev Handles fee calculation, balance validation, and message publishing
     * @dev Used for POST operations where users relay the VAA themselves
     */
    function _postMessage(uint32 nonce, bytes memory payload) internal virtual returns (uint64 sequence) {
        uint256 fee = _coreBridge.messageFee();
        require(address(this).balance >= fee, "Insufficient ETH for wormhole fee");
        sequence = _coreBridge.publishMessage{value: fee}(nonce, payload, CONSISTENCY_LEVEL);
    }
    
    function _post(
        uint256 chainId,
        address sponsor,
        uint256 nonce,
        uint256 expires,
        bytes32 witness,
        Lock[] calldata commitments, //lock tag ++ address ++ amount
        bytes calldata allocatorData,
        bytes calldata sponsorSignature,
        bytes32 claimHash,
        bytes32 claimant,
        uint256 claimReductionScalingFactor
    ) internal returns (uint64 sequence) {
        bytes memory message = Message.encode(sponsor, nonce, expires, witness, commitments, allocatorData, sponsorSignature, claimant, claimReductionScalingFactor);
        sequence = _postMessage(uint32(MessagePackingType.SINGLE_POST), message);
        emit SinglePostEvent(chainId, claimHash, sequence);
    }
    /**
     * @notice Publishes a single message via Wormhole core for user self-relay (SINGLE_POST)
     * @dev Uses wormhole.publishMessage() - user must relay VAA to claim chain themselves
     * @dev Includes all data needed to process the message in the payload itself for filler convenience + we already have in execution context
     */
    function post(
        uint256 chainId,
        address sponsor,
        uint256 nonce,
        uint256 expires,
        bytes32 witness,
        Lock[] calldata commitments, //lock tag ++ address ++ amount
        bytes calldata allocatorData,
        bytes calldata sponsorSignature
    ) external payable virtual refundExcessEth returns (uint64 sequence) {
        (bytes32 claimHash, bytes32 claimant, uint256 claimReductionScalingFactor) =
            _validateBatchClaim(sponsor, nonce, expires, witness, commitments);

        return _post(chainId, sponsor, nonce, expires, witness, commitments, allocatorData, sponsorSignature, claimHash, claimant, claimReductionScalingFactor);

    }

    /**
     * @notice Posts a batch of claim hashes to a single chain via core (BATCH_POST)
     * @dev Public entry point - calls _batchPost() then refunds excess ETH
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
     * @notice Internal function to post a batch of claim hashes without refund logic
     * @dev Used by both batchPost and batchMultichainPost to avoid duplicate refunds
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

        require(encodedBatch.length <= MAX_MESSAGE_SIZE, "Message exceeds max size");

        sequence = _postMessage(uint32(MessagePackingType.BATCH_POST), encodedBatch);

        emit BatchPostEvent(chainId, claimHashes, sequence);
    }

    /**
     * @notice Posts batches of claim hashes to multiple chains via core (multichain BATCH_POST)
     * @dev Loops through chains calling _batchPost(), refunds once at the end
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
     * @notice Receives and processes SEND messages delivered automatically by Wormhole relayer
     * @dev Handles SINGLE_SEND and BATCH_SEND message types via automatic relay
     * @dev Message authentication is guaranteed by the Wormhole relayer before reaching this function
     * @dev See "lib/wormhole-solidity-sdk/src/interfaces/IWormholeReceiver.sol" for interface details
     */
    function _executeVaa(
        bytes calldata payload,
        uint32, // timestamp - unused
        uint32 nonce,
        uint16, // peerChain - unused (validated in parent)
        bytes32, // peerAddress - unused (validated in parent)
        uint64, // sequence - unused
        uint8 // consistencyLevel - unused
    )
        internal
        override
    {
        MessagePackingType messageType = MessagePackingType(nonce);

        if (messageType == MessagePackingType.SINGLE_SEND) {
            _sendClaim(Message.decode(payload));
        } else if (messageType == MessagePackingType.BATCH_SEND) {
            _processBatchSend(payload);
        } else {
            revert("Unsupported message type for relayer delivery");
        }
    }

    /**
     * @notice Internal helper to process BATCH_SEND messages
     * @dev Decodes batch and sends each claim to The Compact
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
     * @dev Handles SINGLE_POST message type via user self-relay with VAA
     * @dev Single POST message contains all the data needed to process the claim in the payload
     * @dev Sending POST logic verifies the claimhash, claimant, and scaling factor correctness
     */
    function receivePost(bytes calldata encodedVaa) external virtual {
        bytes calldata payload = _parseAndValidateVaa(encodedVaa, MessagePackingType.SINGLE_POST);
        _sendClaim(Message.decode(payload));
    }

    //TODO: Implement this
    // impliment per the efficency logic in lib/wormhole-solidity-sdk/src/libraries/CoreBridge.sol
    function receivePosts(bytes[] calldata encodedVAs) external virtual {}

    /**
     * @notice Receives and processes a batch POST message relayed by user via VAA
     * @dev Handles BATCH_POST message type via user self-relay with VAA
     */
    function receiveBatchPost(bytes calldata encodedVaa, BatchClaimWithLocks[] calldata claims) external virtual {
        bytes calldata payload = _parseAndValidateVaa(encodedVaa, MessagePackingType.BATCH_POST);
        (bytes32[] memory claimants, bytes32[] memory claimHashes, uint256[] memory scalingFactors) =
            Message.decodeBatchPost(payload);

        for (uint256 i = 0; i < claimants.length; i++) {

            // Validate that the provided claimHash matches the derived claimHash
            require(
                _deriveClaimHash(
                    claims[i].sponsor,
                    claims[i].nonce,
                    claims[i].expires,
                    claims[i].witness,
                    claims[i].commitments
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

                    // Calculate scaled amount
                    uint256 scaledAmount = scalingFactors[i] == 1e18
                        ? lock.amount
                        : (lock.amount * scalingFactors[i]) / 1e18;

                    // Create single Component portion
                    Component[] memory portions = new Component[](1);
                    portions[0] = Component({
                        claimant: uint256(claimants[i]),
                        amount: scaledAmount
                    });

                    // Create BatchClaimComponent
                    batchClaimComponents[j] = BatchClaimComponent({
                        id: id,
                        allocatedAmount: lock.amount,
                        portions: portions
                    });
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

    function _parseAndValidateVaa(bytes calldata encodedVaa, MessagePackingType expectedType)
        internal
        returns (bytes calldata)
    {
        (, // timestamp (unused)
            uint32 nonce,, // emitterChainId (unused)
            bytes32 emitterAddress,, // sequence (unused)
            , // consistencyLevel (unused)
            bytes calldata payload
        ) = CoreBridgeLib.decodeAndVerifyVaaCd(address(_coreBridge), encodedVaa);

        _validateMessageSender(address(uint160(uint256(emitterAddress))));

        require(MessagePackingType(nonce) == expectedType, "Invalid message type");

        return payload;
    }
}
