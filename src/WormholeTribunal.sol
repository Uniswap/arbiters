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
import {MessagePackingType, SendData, BatchPost, BatchSend} from "./types/WormholeTypes.sol";

/**
 * @title WormholeTribunal
 * @notice Cross-chain message bridge for The Compact using Wormhole infrastructure
 * @dev Implements bidirectional message flow between fill chains and claim chains
 */

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
    // =========================== internal helpers ===========================
    // ========================================================================

    /**
     * @notice Modifier to automatically refund excess ETH after function execution
     * @dev Follows the router pattern - refunds entire contract balance to msg.sender
     */
    modifier refundExcessEth() {
        _;
        _refundExcessEth();
    }

    /**
     * @notice Internal function to refund excess ETH to msg.sender
     * @dev Refunds entire contract balance to msg.sender
     */
    function _refundExcessEth() internal {
        uint256 toRefund = address(this).balance;
        if (toRefund > 0) {
            (bool success,) = msg.sender.call{value: toRefund}("");
            require(success, "ETH refund failed");
        }
    }

    /**
     * @notice Publishes a message via Wormhole core contract
     * @dev Handles fee calculation, balance validation, and message publishing
     * @return sequence The Wormhole message sequence number
     */
    function _publishMessage(uint32 nonce, bytes memory payload) internal returns (uint64 sequence) {
        uint256 fee = WORMHOLE.messageFee();
        require(address(this).balance >= fee, "Insufficient ETH for wormhole fee");

        sequence = WORMHOLE.publishMessage{value: fee}(nonce, payload, CONSISTENCY_LEVEL);
    }

    /**
     * @notice Sends a message via Wormhole relayer for automatic delivery
     * @dev Handles fee calculation, balance validation, and relayer invocation
     * @return dispensation The amount of ETH spent on the relayer fee
     */
    function _sendViaRelayer(uint16 wormholeChainId, bytes memory payload, uint256 gasLimit)
        internal
        returns (uint256 dispensation)
    {
        (dispensation,) = WORMHOLE_RELAYER.quoteEVMDeliveryPrice(wormholeChainId, 0, gasLimit);
        require(address(this).balance >= dispensation, "Insufficient ETH for wormhole relayer fee");

        WORMHOLE_RELAYER.sendPayloadToEvm{value: dispensation}(wormholeChainId, address(this), payload, 0, gasLimit);
    }

    /**
     * @notice Validates that a message came from the corresponding tribunal on another chain
     * @dev Checks that the emitter address matches this contract's address (deterministic across chains)
     * @param emitter The address of the message emitter to validate
     */
    function _validateTribunalAddress(address emitter) internal view {
        require(emitter == address(this), "Message not from corresponding tribunal");
    }

    // ========================================================================
    // ============ FILL CHAIN: Single Message Operations ====================
    // ========================================================================

    /**
     * @notice Quotes the cost to send a single message using the Wormhole relayer
     * @dev Overrides Tribunal._quoteDirective() to provide Wormhole-specific pricing
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
        (dispensation,) = WORMHOLE_RELAYER.quoteEVMDeliveryPrice(WormholeMappings.toWormholeId(chainId), 0, GAS_LIMIT);

        return dispensation;
    }

    /**
     * @notice Sends a single message via Wormhole relayer with automatic delivery (SINGLE_SEND)
     * @dev Overrides Tribunal._processDirective() to send via wormholeRelayer.sendPayloadToEvm()
     */
    function _processDirective(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        bytes32 claimant,
        uint256[] memory claimAmounts,
        uint256 /*unused target block*/
    ) internal virtual override refundExcessEth {
        bytes memory message =
            Message.encode(compact, sponsorSignature, allocatorSignature, mandateHash, claimant, claimAmounts);

        //TODO need to append the MessagePackingType.SINGLE_SEND to the message

        uint16 wormholeChainId = WormholeMappings.toWormholeId(chainId);

        // Send message via Wormhole relayer
        _sendViaRelayer(wormholeChainId, message, GAS_LIMIT);
    }

    /**
     * @notice Publishes a single message via Wormhole core for user self-relay (SINGLE_POST)
     * @dev Uses wormhole.publishMessage() - user must relay VAA to claim chain themselves
     * @dev Includes all data needed to process the message in the payload itself
     */
    function _post(
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        bytes32 claimant,
        uint256[] memory claimAmounts
    ) internal refundExcessEth returns (uint64 messageSequence) {
        // Encode the message with all data for filler convenience
        bytes memory message =
            Message.encode(compact, sponsorSignature, allocatorSignature, mandateHash, claimant, claimAmounts);

        // Publish message via Wormhole core
        messageSequence = _publishMessage(uint32(MessagePackingType.SINGLE_POST), message);
    }

    // ========================================================================
    // ============ FILL CHAIN: Batch Operations ==============================
    // ========================================================================

    /**
     * @notice Sends a batch of full message data to a single chain via relayer (BATCH_SEND)
     * @dev Public entry point - calls _batchSend() then refunds excess ETH
     */
    function batchSend(uint256 chainId, SendData[] memory messages, uint256 gasLimit)
        public
        payable
        virtual
        refundExcessEth
    {
        _batchSend(chainId, messages, gasLimit);
    }

    /**
     * @notice Internal function to send a batch of full messages without refund logic
     * @dev Used by both batchSend and batchMultichainSend to avoid duplicate refunds
     */
    function _batchSend(uint256 chainId, SendData[] memory messages, uint256 gasLimit) internal virtual {
        // Encode the batch using Message.encodeBatchSend(chainId, messages)
        bytes memory encodedBatch = Message.encodeBatchSend(chainId, messages);

        //todo need to append the MessagePackingType.BATCH_SEND to the encodedBatch

        // Enforce max message size
        require(encodedBatch.length <= MAX_MESSAGE_SIZE, "Message exceeds max size");

        // Convert chainId to Wormhole format
        uint16 wormholeChainId = WormholeMappings.toWormholeId(chainId);

        // Send message via Wormhole relayer
        _sendViaRelayer(wormholeChainId, encodedBatch, gasLimit);
    }

    /**
     * @notice Posts a batch of claim hashes to a single chain via core (BATCH_POST)
     * @dev Public entry point - calls _batchPost() then refunds excess ETH
     * @return sequence The Wormhole message sequence number
     */
    function batchPost(uint256 chainId, bytes32[] memory claimHashes)
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
     * @return sequence The Wormhole message sequence number
     */
    function _batchPost(uint256 chainId, bytes32[] memory claimHashes) internal virtual returns (uint64 sequence) {
        // Encode the batch using Message.encodeBatchPost(chainId, claimHashes)
        bytes memory encodedBatch = Message.encodeBatchPost(chainId, claimHashes);

        // Enforce max message size
        require(encodedBatch.length <= MAX_MESSAGE_SIZE, "Message exceeds max size");

        // Publish message via Wormhole core
        sequence = _publishMessage(uint32(MessagePackingType.BATCH_POST), encodedBatch);
    }

    /**
     * @notice Posts batches of claim hashes to multiple chains via core (multichain BATCH_POST)
     * @dev Loops through chains calling _batchPost(), refunds once at the end
     */
    function batchMultichainPost(BatchPost[] memory batches) public payable virtual refundExcessEth {
        // Loop through batches and call _batchPost for each
        unchecked {
            for (uint256 i = 0; i < batches.length; ++i) {
                BatchPost memory batch = batches[i];

                // Call internal _batchPost which doesn't refund
                _batchPost(batch.chainId, batch.claimHashes);
            }
        }
    }

    /**
     * @notice Sends batches of full message data to multiple chains via relayer (multichain BATCH_SEND)
     * @dev Loops through chains calling _batchSend(), refunds once at the end
     */
    function batchMultichainSend(BatchSend[] memory batches, uint256[] memory gasLimits)
        public
        payable
        virtual
        refundExcessEth
    {
        require(batches.length == gasLimits.length, "Batches and gasLimits length mismatch");

        // Loop through batches and call _batchSend for each
        unchecked {
            for (uint256 i = 0; i < batches.length; ++i) {
                BatchSend memory batch = batches[i];

                // Call internal _batchSend which doesn't refund
                _batchSend(batch.chainId, batch.messages, gasLimits[i]);
            }
        }
    }

    // ========================================================================
    // ============ CLAIM CHAIN: Receive & Execute ============================
    // ========================================================================

    /**
     * @notice Receives and processes POST messages relayed by users via VAA
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
     * @return messageSequence The sequence number of the processed message
     */
    function receiveMessage(bytes memory encodedVaa, bytes memory additionalData)
        public
        payable
        returns (uint64 messageSequence)
    {
        // call the Wormhole core contract to parse and verify the encodedVAA
        (IWormhole.VM memory wormholeMessage, bool valid, string memory reason) = WORMHOLE.parseAndVerifyVM(encodedVaa);

        // confirm that the Wormhole core contract verified the message
        require(valid, reason);

        // Check that the source address is the tribunal's on the source chain
        // do not need to check chainID since tribunal address is deterministic for each chain
        // although, we might want to check the set of chainIDs in case an underlying
        // chain is compromised
        _validateTribunalAddress(address(uint160(uint256(wormholeMessage.emitterAddress))));

        // TODO: Decode message / additionalData based on message type (wormholeMessage.nonce)
        // - Check nonce to determine if SINGLE_POST or BATCH_POST
        // - Decode payload accordingly using Message library functions
        // - Extract claim data from additionalData
        // - Call _sendClaim() for each claim
        // - Return the sequence number from wormholeMessage.sequence
    }

    /**
     * @notice Receives and processes SEND messages delivered automatically by Wormhole relayer
     * @dev Handles SINGLE_SEND and BATCH_SEND message types via automatic relay
     * @dev Message authentication is guaranteed by the Wormhole relayer before reaching this function
     * @dev See "lib/wormhole-solidity-sdk/src/interfaces/IWormholeReceiver.sol" for interface details
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
    ) external payable override {
        // Check that the caller is the Wormhole relayer
        require(msg.sender == address(WORMHOLE_RELAYER), "Only the Wormhole relayer can call this function");

        // Check that the source address is the tribunal's on the source chain
        _validateTribunalAddress(address(uint160(uint256(sourceAddress))));

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

        _sendClaim(sponsor, nonce, expires, allocatorSignature, rawSponsorSignature, witness, claims);
    }

    /**
     * @notice Internal function to construct and submit a batch claim to The Compact
     * @dev Constructs TheCompactBatchClaim payload and calls THE_COMPACT.batchClaim()
     * @dev Handles optional sponsor signature validation (checks for non-zero signature)
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
