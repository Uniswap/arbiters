// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;
//compact imports
import {BatchClaim as TheCompactBatchClaim} from "lib/the-compact/src/types/BatchClaims.sol";
import {BatchCompact} from "the-compact/src/types/EIP712Types.sol";
import {BatchClaimComponent} from "the-compact/src/types/Components.sol";

//tribunal imports
import {Tribunal} from "tribunal/Tribunal.sol";
import {WITNESS_TYPESTRING} from "tribunal/types/TribunalTypeHashes.sol";

//wormhole imports
import {IWormholeRelayer} from "wormhole-solidity-sdk/interfaces/IWormholeRelayer.sol";
import {IWormholeReceiver} from "wormhole-solidity-sdk/interfaces/IWormholeReceiver.sol";
import {IWormhole} from "wormhole-solidity-sdk/interfaces/IWormhole.sol";

//library imports
import {WormholeMappings} from "./libraries/WormholeMappings.sol";
import {Message} from "./libraries/Message.sol";

//type imports
import {SendData} from "./types/BatchTypes.sol";

contract WormholeTribunal is IWormholeReceiver, Tribunal {
    using Message for bytes;

    uint256 constant GAS_LIMIT = 150_000; //constant for now, will need arg unless we precalculate for single
    uint8 constant CONSISTENCY_LEVEL = 201; // safe for now
    uint16 constant MAX_MESSAGE_SIZE = 5_000; // 5KB -- solana can only do 1232 bytes so maybe need to reduce

    IWormholeRelayer public immutable WORMHOLE_RELAYER;
    IWormhole public immutable WORMHOLE;

    constructor() {
        WORMHOLE_RELAYER = IWormholeRelayer(WormholeMappings.getWormholeRelayer(block.chainid));
        WORMHOLE = IWormhole(WormholeMappings.getWormhole(block.chainid));
    }

    // ========================================================================
    // =========================== type definitions ===========================
    // ========================================================================

    /**
     * @notice Enum to distinguish between different message packing types
     * @dev Used to determine how messages are encoded and transmitted
     * - SINGLE_POST: Single message via wormhole.publishMessage() (user self-relay)
     * - SINGLE_SEND: Single message via wormholeRelayer.sendPayloadToEvm() (automatic relay)
     * - BATCH_POST: Batch of claim hashes via wormhole.publishMessage() (user self-relay)
     * - BATCH_SEND: Batch of full messages via wormholeRelayer.sendPayloadToEvm() (automatic relay)
     */
    enum MessagePackingType {
        SINGLE_POST,    // 0
        SINGLE_SEND,    // 1
        BATCH_POST,     // 2
        BATCH_SEND      // 3
    }

    /**
     * @notice Represents a batch of claim hashes for a single destination chain
     * @dev Used for BATCH_POST operations where only claim hashes are transmitted
     */
    struct BatchPost {
        uint256 chainId;
        bytes32[] claimHashes;
    }

    /**
     * @notice Represents a batch of full message data for a single destination chain
     * @dev Used for BATCH_SEND operations where complete SendData is transmitted
     */
    struct BatchSend {
        uint256 chainId;
        SendData[] messages;
    }

    // ========================================================================
    // =========================== destination side ==========================
    // ========================================================================


    /**
     * @dev Quotes a single message using the enshrined Wormhole relayer.
     */
    function _quoteDirective(
        uint256 chainId,
        BatchCompact calldata,
        bytes calldata,
        bytes calldata,
        bytes32,
        bytes32,
        uint256[] memory,
        uint256 
    ) internal view virtual override returns (uint256 dispensation) {

        // Get a quote for the cost of gas for delivery
        (dispensation, ) = WORMHOLE_RELAYER.quoteEVMDeliveryPrice(
            WormholeMappings.toWormholeId(chainId),
            0,
            GAS_LIMIT
        );

        return dispensation;
    }

    /**
     * @dev Dispatches a single message using the enshrined Wormhole relayer.
     */
    // _send
    function _processDirective( 
        uint256 chainId,
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        bytes32 claimant,
        uint256[] memory claimAmounts,
        uint256 /*unused target block*/
    ) internal virtual override {
        bytes memory message = Message.encode(
            compact,
            sponsorSignature,
            allocatorSignature,
            mandateHash,
            claimant,
            claimAmounts
        );

        //todo need to append the MessagePackingType.SINGLE_SEND to the message

        uint16 wormholeChainId = WormholeMappings.toWormholeId(chainId);

        // Get a quote for the cost of gas for delivery
        (uint256 dispensation, ) = WORMHOLE_RELAYER.quoteEVMDeliveryPrice(wormholeChainId, 0, GAS_LIMIT);

        // Capture balance before sending (includes any remaining msg.value from upstream + forced ETH)
        uint256 balanceBeforeFee = address(this).balance;
        require(balanceBeforeFee >= dispensation, "Insufficient ETH for wormhole relayer fee");

        WORMHOLE_RELAYER.sendPayloadToEvm{value: dispensation}(
            wormholeChainId,
            address(this),
            message,
            0,
            GAS_LIMIT
        );

        // Refund entire remaining balance (router pattern)
        uint256 toRefund = balanceBeforeFee - dispensation;
        if (toRefund > 0) {
            (bool success,) = msg.sender.call{value: toRefund}("");
            require(success, "ETH refund failed");
        }
    }

    // _post -> we include all the data needed to process the message
    // in the message itself for filler ease + there is no calldata savings
    function _post(
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        bytes32 claimant,
        uint256[] memory claimAmounts
    ) internal returns (uint64 messageSequence) {
        
        // Encode the message with all data for filler convenience
        bytes memory message = Message.encode(
            compact,
            sponsorSignature,
            allocatorSignature,
            mandateHash,
            claimant,
            claimAmounts
        );

        uint256 wormholeFee = WORMHOLE.messageFee();
        
        // Capture balance before paying fee (includes any remaining msg.value from upstream + forced ETH)
        uint256 balanceBeforeFee = address(this).balance;
        require(balanceBeforeFee >= wormholeFee, "Insufficient ETH for wormhole fee");

        messageSequence = WORMHOLE.publishMessage{value: wormholeFee}(
            uint32(MessagePackingType.SINGLE_POST),
            message,
            CONSISTENCY_LEVEL
        );

        // Refund entire remaining balance (router pattern)
        uint256 toRefund = balanceBeforeFee - wormholeFee;
        if (toRefund > 0) {
            (bool success,) = msg.sender.call{value: toRefund}("");
            require(success, "ETH refund failed");
        }
    }

    /**
     * @notice Internal function to send a batch of full messages without refund logic
     * @dev Used by both batchSend and batchMultichainSend to avoid duplicate refunds
     * @param chainId The destination chain ID
     * @param messages Array of SendData structs containing full claim information
     * @param gasLimit The gas limit for execution on the destination chain
     */
    function _batchSend(uint256 chainId, SendData[] memory messages, uint256 gasLimit) internal virtual {
        // Validate inputs
        require(chainId != 0, "Invalid chainId");
        require(messages.length > 0, "Empty messages array");
        require(gasLimit > 0, "Invalid gas limit");

        // Encode the batch using Message.encodeBatchSend(chainId, messages)
        bytes memory encodedBatch = Message.encodeBatchSend(chainId, messages);

        //todo need to append the MessagePackingType.BATCH_SEND to the encodedBatch

        // Enforce max message size
        require(encodedBatch.length <= MAX_MESSAGE_SIZE, "Message exceeds max size");

        // Convert chainId to Wormhole format
        uint16 wormholeChainId = WormholeMappings.toWormholeId(chainId);

        // Calculate cost: wormholeRelayer.quoteEVMDeliveryPrice(wormholeChainId, 0, gasLimit)
        (uint256 dispensation, ) = WORMHOLE_RELAYER.quoteEVMDeliveryPrice(wormholeChainId, 0, gasLimit);

        // Validate sufficient balance
        require(address(this).balance >= dispensation, "Insufficient ETH for wormhole relayer fee");

        // Send the batch via wormholeRelayer.sendPayloadToEvm
        WORMHOLE_RELAYER.sendPayloadToEvm{value: dispensation}(
            wormholeChainId,
            address(this),
            encodedBatch,
            0,
            gasLimit
        );
    }

    /**
     * @notice Sends a batch of full message data to a single destination chain with automatic relay
     * @dev Uses wormholeRelayer.sendPayloadToEvm() with MessagePackingType encoded in payload
     * @param chainId The destination chain ID
     * @param messages Array of SendData structs containing full claim information
     * @param gasLimit The gas limit for execution on the destination chain
     */
    function batchSend(uint256 chainId, SendData[] memory messages, uint256 gasLimit) public payable virtual {
        // Call internal function to send batch
        _batchSend(chainId, messages, gasLimit);

        // Refund entire remaining balance (router pattern)
        uint256 toRefund = address(this).balance;
        if (toRefund > 0) {
            (bool success,) = msg.sender.call{value: toRefund}("");
            require(success, "ETH refund failed");
        }
    }

    /**
     * @notice Internal function to post a batch of claim hashes without refund logic
     * @dev Used by both batchPost and batchMultichainPost to avoid duplicate refunds
     * @param chainId The destination chain ID
     * @param claimHashes Array of claim hashes to post
     * @return sequence The Wormhole message sequence number
     */
    function _batchPost(uint256 chainId, bytes32[] memory claimHashes) internal virtual returns (uint64 sequence) {
        // Validate inputs
        require(chainId != 0, "Invalid chainId");
        require(claimHashes.length > 0, "Empty claim hashes array");

        // Encode the batch using Message.encodeBatchPost(chainId, claimHashes)
        bytes memory encodedBatch = Message.encodeBatchPost(chainId, claimHashes);

        // Enforce max message size
        require(encodedBatch.length <= MAX_MESSAGE_SIZE, "Message exceeds max size");

        // Get the Wormhole message fee
        uint256 fee = WORMHOLE.messageFee();

        // Validate sufficient balance
        require(address(this).balance >= fee, "Insufficient ETH for wormhole fee");

        // Publish message with MessagePackingType.BATCH_POST as nonce
        sequence = WORMHOLE.publishMessage{value: fee}(
            uint32(MessagePackingType.BATCH_POST),
            encodedBatch,
            CONSISTENCY_LEVEL
        );
    }

    /**
     * @notice Posts a batch of claim hashes to a single destination chain for user self-relay
     * @dev Uses wormhole.publishMessage() with nonce = MessagePackingType.BATCH_POST
     * @param chainId The destination chain ID
     * @param claimHashes Array of claim hashes to post
     * @return sequence The Wormhole message sequence number
     */
    function batchPost(uint256 chainId, bytes32[] memory claimHashes) public payable virtual returns (uint64 sequence) {
        // Call internal function to post batch
        sequence = _batchPost(chainId, claimHashes);

        // Refund entire remaining balance (router pattern)
        uint256 toRefund = address(this).balance;
        if (toRefund > 0) {
            (bool success,) = msg.sender.call{value: toRefund}("");
            require(success, "ETH refund failed");
        }
    }

    /**
     * @notice Posts batches of claim hashes to multiple destination chains for user self-relay
     * @dev Loops through chains and calls batchPost() for each
     * @param batches Array of BatchPost structs, one per destination chain
     */
    function batchMultichainPost(BatchPost[] memory batches) public payable virtual {
        // Validate inputs
        require(batches.length > 0, "Empty batches array");

        // Loop through batches and call _batchPost for each
        unchecked {
            for (uint256 i = 0; i < batches.length; ++i) {
                BatchPost memory batch = batches[i];

                // Call internal _batchPost which doesn't refund
                _batchPost(batch.chainId, batch.claimHashes);
            }
        }

        // Refund entire remaining balance once at the end (router pattern)
        uint256 toRefund = address(this).balance;
        if (toRefund > 0) {
            (bool success,) = msg.sender.call{value: toRefund}("");
            require(success, "ETH refund failed");
        }
    }

    /**
     * @notice Sends batches of full message data to multiple destination chains with automatic relay
     * @dev Loops through chains and calls _batchSend() for each
     * @param batches Array of BatchSend structs, one per destination chain
     * @param gasLimits Array of gas limits for each batch (must match batches.length)
     */
    function batchMultichainSend(BatchSend[] memory batches, uint256[] memory gasLimits) public payable virtual {
        // Validate inputs
        require(batches.length > 0, "Empty batches array");
        require(batches.length == gasLimits.length, "Batches and gasLimits length mismatch");

        // Loop through batches and call _batchSend for each
        unchecked {
            for (uint256 i = 0; i < batches.length; ++i) {
                BatchSend memory batch = batches[i];

                // Call internal _batchSend which doesn't refund
                _batchSend(batch.chainId, batch.messages, gasLimits[i]);
            }
        }

        // Refund entire remaining balance once at the end (router pattern)
        uint256 toRefund = address(this).balance;
        if (toRefund > 0) {
            (bool success,) = msg.sender.call{value: toRefund}("");
            require(success, "ETH refund failed");
        }
    }


    // ========================================================================
    // =========================== origin side ================================
    // ========================================================================

    /**
     * @notice Receives and processes messages published via wormhole.publishMessage() (POST operations)
     * @dev Handles SINGLE_POST and BATCH_POST message types via user self-relay with VAA
     *
     * Implementation steps:
     * 1. Parse and verify the VAA using wormhole.parseAndVerifyVM(encodedVAA)
     * 2. Validate the message is from the corresponding tribunal on source chain
     * 3. Extract nonce from wormholeMessage.nonce to get MessagePackingType
     * 4. If nonce == SINGLE_POST:
     *    - Decode single claim hash from payload
     *    - Process single claim using additionalData (which contains full SendData)
     * 5. If nonce == BATCH_POST:
     *    - Decode batch of claim hashes using Message.decodeBatchPost()
     *    - Process each claim using corresponding entry in additionalData array
     * 6. Emit appropriate events
     *
     * @param encodedVaa The Wormhole VAA containing the message
     * @param additionalData Additional data needed to process claims (SendData or array)
     * @return messageSequence The sequence number of the processed message
     */
    function receiveMessage(
        bytes memory encodedVaa,
        bytes memory additionalData
    ) public payable returns (uint64 messageSequence) {

        // call the Wormhole core contract to parse and verify the encodedVAA
        (
            IWormhole.VM memory wormholeMessage,
            bool valid,
            string memory reason
        ) = WORMHOLE.parseAndVerifyVM(encodedVaa);

        // confirm that the Wormhole core contract verified the message
        require(valid, reason);

        // Check that the source address is the tribunal's on the source chain
        // do not need to check chainID since tribunal address is deterministic for each chain
        // although, we might want to check the set of chainIDs in case an underlying
        // chain is compromised 
        require(
            address(uint160(uint256(wormholeMessage.emitterAddress))) == address(this),
            "Message not from corresponding tribunal"
        );

        // TODO: Decode message / additionalData based on message type (wormholeMessage.nonce)
        // - Check nonce to determine if SINGLE_POST or BATCH_POST
        // - Decode payload accordingly using Message library functions
        // - Extract claim data from additionalData
        // - Call _sendClaim() for each claim
        // - Return the sequence number from wormholeMessage.sequence

    }

    /**
     * @notice Receives and processes messages sent via wormholeRelayer.sendPayloadToEvm() (SEND operations)
     * @dev Handles SINGLE_SEND and BATCH_SEND message types via automatic relay
     * As this endpoint is only invoked by the enshrined Wormhole relayer,
     * message authentication is guaranteed before reaching this function.
     * See "lib/wormhole-solidity-sdk/src/interfaces/IWormholeReceiver.sol" for more information.
     *
     * Current implementation: Handles SINGLE_SEND messages only
     *
     * TODO: Add BATCH_SEND support:
     * 1. Check first byte of payload for MessagePackingType
     * 2. If MessagePackingType == SINGLE_SEND (or no type byte for backwards compatibility):
     *    - Use existing decode logic (payload.decode())
     *    - Call _sendClaim() once
     * 3. If MessagePackingType == BATCH_SEND:
     *    - Decode batch using Message.decodeBatchSend(payload)
     *    - Loop through each MessageData in the batch
     *    - Call _sendClaim() for each message
     * 4. Emit appropriate events for batch processing
     */
    function receiveWormholeMessages(
        bytes calldata payload,
        bytes[] memory additionalMessages,
        bytes32 sourceAddress,
        uint16 sourceChain,
        bytes32 deliveryHash
    ) external override payable {

        // Check that the caller is the Wormhole relayer
        require(
            msg.sender == address(WORMHOLE_RELAYER),
            "Only the Wormhole relayer can call this function"
        );

        // Check that the source address is the tribunal's on the source chain
        require(
            address(uint160(uint256(sourceAddress))) == address(this),
            "Message not from corresponding tribunal"
        );

        // TODO: Check first byte of payload for MessagePackingType to determine if batch
        // For now, assume SINGLE_SEND and decode as single message

        // Decode the message
        (
            address sponsor,
            uint256 nonce,
            uint256 expires,
            bytes calldata allocatorSignature,
            bytes calldata rawSponsorSignature,
            bytes32 witness,
            BatchClaimComponent[] memory claims
        ) = payload.decode();

        _sendClaim(
            sponsor,
            nonce,
            expires,
            allocatorSignature,
            rawSponsorSignature,
            witness,
            claims
        );
    }

    /**
     * @dev Internal function to construct and submit a batch claim to The Compact.
     */
    function _sendClaim(
        address sponsor,
        uint256 nonce,
        uint256 expires,
        bytes calldata allocatorSignature,
        bytes calldata rawSponsorSignature,
        bytes32 witness,
        BatchClaimComponent[] memory claims
    ) internal {
        // Only assign sponsorSignature if provided signature has nonzero bytes
        bytes memory sponsorSignature;
        if (
            keccak256(rawSponsorSignature)
                != bytes32(0xad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5)
        ) {
            sponsorSignature = rawSponsorSignature;
        }

        TheCompactBatchClaim memory claimPayload = TheCompactBatchClaim({
            allocatorData: allocatorSignature,
            sponsorSignature: sponsorSignature,
            sponsor: sponsor,
            nonce: nonce,
            expires: expires,
            witness: witness,
            witnessTypestring: WITNESS_TYPESTRING,
            claims: claims
        });

        THE_COMPACT.batchClaim(claimPayload);

    }

}