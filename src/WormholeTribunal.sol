// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;
//compact imports
import {ITheCompactClaims} from "the-compact/src/interfaces/ITheCompactClaims.sol";
import {BatchClaim as TheCompactBatchClaim} from "lib/the-compact/src/types/BatchClaims.sol";
import {Component} from "the-compact/src/types/Components.sol";
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

contract WormholeTribunal is IWormholeReceiver, Tribunal {
    using Message for bytes;

    uint256 constant GAS_LIMIT = 150_000; //constant for now, will need arg unless we precalculate for single
    uint8 constant CONSISTENCY_LEVEL = 201; // safe for now
    uint16 constant MAX_MESSAGE_SIZE = 5_000; // 5KB -- solana can only do 1232 bytes so maybe need to reduce

    IWormholeRelayer public immutable wormholeRelayer;
    IWormhole public immutable wormhole;

    constructor() {
        wormholeRelayer = IWormholeRelayer(WormholeMappings.getWormholeRelayer(block.chainid));
        wormhole = IWormhole(WormholeMappings.getWormhole(block.chainid));
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

    /**
     * @notice Represents a batch of claim hashes for a single destination chain
     * @dev Used for BATCH_POST operations where only claim hashes are transmitted
     */
    struct BatchClaim {
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
        (dispensation, ) = wormholeRelayer.quoteEVMDeliveryPrice(
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
        (uint256 dispensation, ) = wormholeRelayer.quoteEVMDeliveryPrice(wormholeChainId, 0, GAS_LIMIT);

        // Capture balance before sending (includes any remaining msg.value from upstream + forced ETH)
        uint256 balanceBeforeFee = address(this).balance;
        require(balanceBeforeFee >= dispensation, "Insufficient ETH for wormhole relayer fee");

        wormholeRelayer.sendPayloadToEvm{value: dispensation}(
            wormholeChainId,
            address(this),
            message,
            0,
            GAS_LIMIT
        );

        // Refund entire remaining balance (router pattern)
        uint256 toRefund = balanceBeforeFee - dispensation;
        if (toRefund > 0) {
            msg.sender.safeTransferETH(toRefund);
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

        uint256 wormholeFee = wormhole.messageFee();
        
        // Capture balance before paying fee (includes any remaining msg.value from upstream + forced ETH)
        uint256 balanceBeforeFee = address(this).balance;
        require(balanceBeforeFee >= wormholeFee, "Insufficient ETH for wormhole fee");

        messageSequence = wormhole.publishMessage{value: wormholeFee}(
            uint32(MessagePackingType.SINGLE_POST),
            message,
            CONSISTENCY_LEVEL
        );

        // Refund entire remaining balance (router pattern)
        uint256 toRefund = balanceBeforeFee - wormholeFee;
        if (toRefund > 0) {
            msg.sender.safeTransferETH(toRefund);
        }
    }

    /**
     * @notice Sends a batch of full message data to a single destination chain with automatic relay
     * @dev Uses wormholeRelayer.sendPayloadToEvm() with MessagePackingType encoded in payload
     * @param chainId The destination chain ID
     * @param messages Array of SendData structs containing full claim information
     * @param gasLimit The gas limit for execution on the destination chain
     */
    function batchSend(uint256 chainId, SendData[] memory messages, uint256 gasLimit) public payable virtual {
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
        (uint256 dispensation, ) = wormholeRelayer.quoteEVMDeliveryPrice(wormholeChainId, 0, gasLimit);

        // Capture balance before sending (includes any remaining msg.value from upstream + forced ETH)
        uint256 balanceBeforeFee = address(this).balance;
        require(balanceBeforeFee >= dispensation, "Insufficient ETH for wormhole relayer fee");

        // Send the batch via wormholeRelayer.sendPayloadToEvm
        wormholeRelayer.sendPayloadToEvm{value: dispensation}(
            wormholeChainId,
            address(this),
            encodedBatch,
            0,
            gasLimit
        );

        // Refund entire remaining balance (router pattern)
        uint256 toRefund = balanceBeforeFee - dispensation;
        if (toRefund > 0) {
            msg.sender.safeTransferETH(toRefund);
        }
    }


        /**
     * @notice Posts a batch of claim hashes to a single destination chain for user self-relay
     * @dev Uses wormhole.publishMessage() with nonce = MessagePackingType.BATCH_POST
     *
     * Implementation steps:
     * 1. Encode the batch using Message.encodeBatchPost(chainId, claimHashes)
     * 2. Get the Wormhole message fee: wormhole.messageFee()
     * 3. Validate msg.value >= wormholeFee
     * 4. Call wormhole.publishMessage{value: wormholeFee}(
     *      uint32(MessagePackingType.BATCH_POST),  // nonce indicates message type
     *      encodedBatch,
     *      CONSISTENCY_LEVEL
     *    )
     * 5. Return the sequence number
     *
     * @param chainId The destination chain ID
     * @param claimHashes Array of claim hashes to post
     * @return sequence The Wormhole message sequence number
     */
    // probably want read function to make sure its not gonna be too big and claim hashes are valid
    function batchPost(uint256 chainId, bytes32[] memory claimHashes) public payable virtual returns (uint64 sequence) {

        // Encode the batch using Message.encodeBatchPost(chainId, claimHashes)
        
        // need to check the max message size

        // Get the Wormhole message fee: wormhole.messageFee()

        // Capture balance before paying fee (includes any remaining msg.value from upstream + forced ETH)

        //wormhole.publishMessage{value: wormholeFee} with nonce = MessagePackingType.BATCH_POST

        // Refund entire remaining balance (router pattern)

    }

    /**
     * @notice Posts batches of claim hashes to multiple destination chains for user self-relay
     * @dev Loops through chains and calls batchPost() for each
     *
     * Implementation steps:
     * 1. Calculate total wormhole fee: batches.length * wormhole.messageFee()
     * 2. Validate msg.value >= totalFee
     * 3. Loop through batches array:
     *    - Call batchPost{value: wormholeFee}(batch.chainId, batch.claimHashes)
     *    - Track total fees used
     * 4. Refund excess if any: msg.value - totalFeesUsed
     *
     * @param batches Array of BatchClaim structs, one per destination chain
     */
    function batchMultichainPost(BatchClaim[] memory batches) public payable virtual {
        // this just loops through the batches and calls batchPost for each

        // might need to make an internal function for batchPost for refund behavior
    }

    /**
     * @notice Sends batches of full message data to multiple destination chains with automatic relay
     * @dev Loops through chains and calls batchSend() for each
     *
     * Implementation steps:
     * 1. Pre-calculate total cost across all chains:
     *    - For each batch: get wormholeChainId and call quoteEVMDeliveryPrice()
     *    - Sum all costs
     * 2. Validate msg.value >= totalCost
     * 3. Loop through batches array:
     *    - Calculate individual batch cost
     *    - Call batchSend{value: batchCost}(batch.chainId, batch.messages)
     * 4. Refund excess if any: msg.value - totalCostUsed
     *
     * @param batches Array of BatchSend structs, one per destination chain
     */
    function batchMultichainSend(BatchSend[] memory batches) public payable virtual {
        // this just loops through the batches and calls batchSend for each

        // might need to make an internal function for batchSend for refund behavior
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
     * @param encodedVAA The Wormhole VAA containing the message
     * @param additionalData Additional data needed to process claims (SendData or array)
     * @return messageSequence The sequence number of the processed message
     */
    function receiveMessage(
        bytes memory encodedVAA,
        bytes memory additionalData
    ) public payable returns (uint64 messageSequence) {

        // call the Wormhole core contract to parse and verify the encodedVAA
        (
            IWormhole.VM memory wormholeMessage,
            bool valid,
            string memory reason
        ) = wormhole.parseAndVerifyVM(encodedVAA);

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
            msg.sender == address(wormholeRelayer),
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