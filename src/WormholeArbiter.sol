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
import {IWormholeArbiter} from "./interfaces/IWormholeArbiter.sol";

/**
 * @notice Cross-chain arbiter for The Compact using Wormhole infrastructure
 * @dev Relays fills from the Tribunal on the target chain to the origin chain via
 * Wormhole, then submits claim data to The Compact for settlement.
 *
 * TWO OPERATIONAL MODES:
 * ┌─────────────────────────────────────────────────────────────┐
 * │ SEND (automatic relay)     │ POST (self-relay)              │
 * ├────────────────────────────┼────────────────────────────────┤
 * │ Uses Wormhole Executor     │ Uses Wormhole Core only        │
 * │ Relayer delivers message   │ User fetches VAA & submits     │
 * │ Higher cost (relay fees)   │ Lower cost (just message fee)  │
 * │ Automatic delivery         │ Manual delivery required       │
 * └─────────────────────────────────────────────────────────────┘
 *
 * ENTRY POINTS (Source Chain - sending claims):
 * - dispatchCallback()           Tribunal calls after fill validation
 * - send() / batchSend()         Direct SEND (bypasses Tribunal)
 * - post() / batchPost()         Direct POST (bypasses Tribunal)
 * - multichainBatch{Send,Post}() Multiple chains in one tx
 *
 * ENTRY POINTS (Destination Chain - receiving claims):
 * - executeVAAv1                 Wormhole Executor calls (SEND mode) [in WormholeExecutor.sol]
 * - receivePost()                User calls with VAA (POST mode)
 * - receiveBatchPost()           User calls with VAA + claim data
 *
 * HELPERS (for off-chain context construction):
 * - encodeSendContext()          Build context for SEND via Tribunal
 * - encodePostContext()          Build context for POST via Tribunal
 */

contract WormholeArbiter is ExecutorSendReceive, IDispatchCallback, IWormholeArbiter, BaseArbiter {
    // TODO: decide on consistency levels
    uint8 constant CONSISTENCY_LEVEL = 201; // safe for now. maybe custom in the future
    // TODO: decide on max message size
    uint16 constant MAX_MESSAGE_SIZE = 5_000; // 5KB -- solana can only do 1232 bytes so maybe need to reduce

    constructor()
        ExecutorSendReceive(
            WormholeMappings.getWormhole(block.chainid), WormholeMappings.getWormholeExecutor(block.chainid)
        )
    {} // TODO enforce checks on tribunal in deployment maybe? maybe verify witnesses / pull them

    // ======== External Functions ========

    /// @inheritdoc IDispatchCallback
    /// @dev Routes to SEND or POST based on context flags.
    ///      Context first byte: 0x04 = SEND (executor delivery), 0x00 = POST (self-relay)
    function dispatchCallback(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes32 mandateHash,
        bytes32 claimHash,
        bytes32 claimant,
        uint256 claimReductionScalingFactor,
        uint256[] calldata, //claimAmounts unused
        bytes calldata context
    ) external payable refundExcessEth returns (bytes4) {
        if (msg.sender != TRIBUNAL_ADDRESS) revert UnauthorizedCaller();
        if (compact.arbiter != address(this)) revert InvalidArbiter();
        if (context.length < 1) revert ContextTooShort();

        uint8 flags;
        assembly {
            flags := byte(0, calldataload(context.offset))
        }

        bytes calldata allocatorData;
        bytes calldata sponsorSignature;

        if ((flags & Message.IS_SEND) != 0) {
            WormholeParams memory wormholeParams;
            bytes calldata signedQuote;

            // TODO: try to get rid of wormhole params assignment here. did this for now because of stack too deep error.
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

            emit SingleSendEvent(chainId, claimHash, sequence);
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

    /// @inheritdoc IWormholeArbiter
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

    /// @inheritdoc IWormholeArbiter
    function batchSend(BatchSend calldata batch) external payable virtual refundExcessEth returns (uint64 sequence) {
        return _batchSend(batch);
    }

    /// @inheritdoc IWormholeArbiter
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

    /// @inheritdoc IWormholeArbiter
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

    /// @inheritdoc IWormholeArbiter
    function batchPost(uint256 chainId, bytes32[] calldata claimHashes)
        external
        payable
        virtual
        refundExcessEth
        returns (uint64 sequence)
    {
        sequence = _batchPost(chainId, claimHashes);
    }

    /// @inheritdoc IWormholeArbiter
    function multichainBatchPost(BatchPost[] calldata batches)
        external
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

    /// @inheritdoc IWormholeArbiter
    function receivePost(bytes calldata encodedVaa) external virtual {
        bytes calldata payload = _parseAndValidateVaa(encodedVaa, MessagePackingType.SINGLE_POST);
        _sendClaim(Message.decode(payload));
    }

    /// @inheritdoc IWormholeArbiter
    function receivePosts(bytes[] calldata encodedVAs) external virtual {}

    /// @inheritdoc IWormholeArbiter
    function receiveBatchPost(bytes calldata encodedVaa, BatchClaimWithLocks[] calldata claims) external virtual {
        bytes calldata payload = _parseAndValidateVaa(encodedVaa, MessagePackingType.BATCH_POST);
        (bytes32[] memory claimants, bytes32[] memory claimHashes, uint256[] memory scalingFactors) =
            Message.decodeBatchPost(payload);

        for (uint256 i = 0; i < claimants.length; i++) {
            if (
                _deriveClaimHash(
                        claims[i].sponsor, claims[i].nonce, claims[i].expires, claims[i].witness, claims[i].commitments
                    ) != claimHashes[i] //validate that the provided claimHash matches the derived claimHash
            ) revert InvalidClaimHash();

            BatchClaim memory claim = BatchClaim({
                allocatorData: claims[i].allocatorData,
                sponsorSignature: claims[i].sponsorSignature,
                sponsor: claims[i].sponsor,
                nonce: claims[i].nonce,
                expires: claims[i].expires,
                witness: claims[i].witness,
                witnessTypestring: WITNESS_TYPESTRING,
                claims: _buildBatchClaimComponents(claims[i].commitments, claimants[i], scalingFactors[i])
            });

            _sendClaim(claim);
        }
    }

    // ======== External Pure Functions ========

    /// @inheritdoc IWormholeArbiter
    function encodeSendContext(
        bytes calldata allocatorData,
        bytes calldata sponsorSignature,
        WormholeParams memory params,
        bytes calldata signedQuote
    ) external pure returns (bytes memory) {
        return Message.encodeSendContext(allocatorData, sponsorSignature, params, signedQuote);
    }

    /// @inheritdoc IWormholeArbiter
    function encodePostContext(bytes calldata allocatorData, bytes calldata sponsorSignature)
        external
        pure
        returns (bytes memory)
    {
        return Message.encodePostContext(allocatorData, sponsorSignature);
    }

    // ======== Internal Functions ========

    /// @dev Wraps _publishAndRelay with CONSISTENCY_LEVEL and refund to msg.sender
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

    /// @dev Validates claims, encodes batch, enforces MAX_MESSAGE_SIZE
    function _batchSend(BatchSend calldata batch) internal virtual returns (uint64 sequence) {
        bytes32[] memory claimHashes = new bytes32[](batch.claims.length);
        bytes32[] memory claimants = new bytes32[](batch.claims.length);
        uint256[] memory scalingFactors = new uint256[](batch.claims.length);

        unchecked {
            for (uint256 i = 0; i < batch.claims.length; ++i) {
                (claimHashes[i], claimants[i], scalingFactors[i]) = _validateBatchClaim(
                    batch.claims[i].sponsor,
                    batch.claims[i].nonce,
                    batch.claims[i].expires,
                    batch.claims[i].witness,
                    batch.claims[i].commitments
                );
            }
        }

        bytes memory encodedBatch = Message.encodeBatchSend(claimants, scalingFactors, batch.claims);

        if (encodedBatch.length > MAX_MESSAGE_SIZE) revert MessageExceedsMaxSize();

        sequence = _sendMessage(
            encodedBatch,
            batch.totalCost,
            batch.chainId,
            batch.signedQuote,
            batch.gasLimit,
            uint32(MessagePackingType.BATCH_SEND)
        );

        emit BatchSendEvent(batch.chainId, claimHashes, sequence);
    }

    /// @dev Wraps _coreBridge.publishMessage with CONSISTENCY_LEVEL
    function _postMessage(uint32 nonce, bytes memory payload) internal virtual returns (uint64 sequence) {
        uint256 fee = _coreBridge.messageFee();
        if (address(this).balance < fee) revert InsufficientFee();
        sequence = _coreBridge.publishMessage{value: fee}(nonce, payload, CONSISTENCY_LEVEL);
    }

    /// @dev Validates claims via Tribunal.filled(), encodes with bitmap compression
    function _batchPost(uint256 chainId, bytes32[] calldata claimHashes) internal virtual returns (uint64 sequence) {
        if (claimHashes.length > 120) revert TooManyClaims();

        bytes32[] memory claimants = new bytes32[](claimHashes.length);
        uint256[] memory scalingFactors = new uint256[](claimHashes.length);

        unchecked {
            for (uint256 i = 0; i < claimHashes.length; ++i) {
                claimants[i] = TRIBUNAL.filled(claimHashes[i]);
                if (claimants[i] == bytes32(0)) revert ClaimNotFilled();
                scalingFactors[i] = TRIBUNAL.claimReductionScalingFactor(claimHashes[i]);
            }
        }

        bytes memory encodedBatch = Message.encodeBatchPost(claimants, claimHashes, scalingFactors);
        sequence = _postMessage(uint32(MessagePackingType.BATCH_POST), encodedBatch);

        emit BatchPostEvent(chainId, claimHashes, sequence);
    }

    /// @dev Handles SEND messages from Wormhole executor, validates chain + emitter
    function _executeVaa(
        bytes calldata payload,
        uint32, // timestamp (unused)
        uint32 nonce,
        uint16 peerChain,
        bytes32 emitterAddress,
        uint64, // sequence (unused)
        uint8
    ) internal override {
        MessagePackingType messageType = MessagePackingType(nonce);

        // validate that the emitter chain is supported to prevent messages from unsupported/compromised chains
        WormholeMappings.validateChainId(peerChain);

        _validateMessageSender(address(uint160(uint256(emitterAddress))));

        if (messageType == MessagePackingType.SINGLE_SEND) {
            _sendClaim(Message.decode(payload));
        } else if (messageType == MessagePackingType.BATCH_SEND) {
            _processBatchSend(payload);
        } else {
            revert UnsupportedMessageType();
        }
    }

    /// @dev Decodes BATCH_SEND and submits each claim to The Compact
    function _processBatchSend(bytes calldata payload) internal virtual {
        BatchClaim[] memory claims = Message.decodeBatchSend(payload);
        unchecked {
            for (uint256 i = 0; i < claims.length; ++i) {
                _sendClaim(claims[i]);
            }
        }
    }

    /// @dev Verifies VAA, validates chain + emitter + message type
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

        // validate that the emitter chain is supported to prevent messages from unsupported/compromised chains
        WormholeMappings.validateChainId(emitterChainId);

        _validateMessageSender(address(uint160(uint256(emitterAddress))));

        if (MessagePackingType(nonce) != expectedType) revert InvalidMessageType();

        return payload;
    }

    /// @dev Transforms Lock[] into BatchClaimComponent[] with scaling factor applied
    function _buildBatchClaimComponents(Lock[] calldata commitments, bytes32 claimant, uint256 scalingFactor)
        internal
        pure
        returns (BatchClaimComponent[] memory batchClaimComponents)
    {
        batchClaimComponents = new BatchClaimComponent[](commitments.length);

        unchecked {
            for (uint256 j = 0; j < commitments.length; ++j) {
                Lock calldata lock = commitments[j];
                uint256 id = uint256(bytes32(lock.lockTag)) | uint256(uint160(lock.token));

                Component[] memory portions;
                if (scalingFactor == 0) {
                    // Empty portions array for cancelled claims (zero scaling factor)
                    portions = new Component[](0);
                } else {
                    uint256 scaledAmount = scalingFactor == 1e18 ? lock.amount : (lock.amount * scalingFactor) / 1e18;
                    portions = new Component[](1);
                    portions[0] = Component({claimant: uint256(claimant), amount: scaledAmount});
                }

                batchClaimComponents[j] =
                    BatchClaimComponent({id: id, allocatedAmount: lock.amount, portions: portions});
            }
        }
    }
}
