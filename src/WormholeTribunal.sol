// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;
//compact imports
import {BatchClaim as TheCompactBatchClaim} from "lib/the-compact/src/types/BatchClaims.sol";
import {BatchCompact} from "the-compact/src/types/EIP712Types.sol";
import {BatchClaimComponent} from "the-compact/src/types/Components.sol";
import {ClaimHashLib} from "lib/the-compact/src/lib/ClaimHashLib.sol";


//tribunal imports
import {Tribunal} from "tribunal/Tribunal.sol";
import {WITNESS_TYPESTRING} from "tribunal/types/TribunalTypeHashes.sol";

//wormhole imports
import {IWormholeRelayer} from "wormhole-solidity-sdk/interfaces/IWormholeRelayer.sol";
import {IWormholeReceiver} from "wormhole-solidity-sdk/interfaces/IWormholeReceiver.sol";
import {IWormhole} from "wormhole-solidity-sdk/interfaces/IWormhole.sol";

//library and type imports
import {WormholeMappings} from "./libraries/WormholeMappings.sol";
import {Message} from "./libraries/Message.sol";
import {MessagePackingType, BatchPost, BatchSend} from "./types/WormholeTypes.sol";

/**
 * @title WormholeTribunal
 * @notice Cross-chain message bridge for The Compact using Wormhole infrastructure
 * @dev Implements bidirectional message flow between fill chains and claim chains
 */

contract WormholeTribunal is IWormholeReceiver, Tribunal {
    using Message for bytes;
    using ClaimHashLib for TheCompactBatchClaim;  

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
     */
    function _publishMessage(uint32 nonce, bytes memory payload) internal returns (uint64 sequence) {
        uint256 fee = WORMHOLE.messageFee();
        require(address(this).balance >= fee, "Insufficient ETH for wormhole fee");
        sequence = WORMHOLE.publishMessage{value: fee}(nonce, payload, CONSISTENCY_LEVEL);
    }

    /**
     * @notice Sends a message via Wormhole relayer for automatic delivery
     * @dev Handles fee calculation, balance validation, and relayer invocation
     */
    function _sendViaRelayer(uint16 wormholeChainId, bytes memory payload, uint256 gasLimit)
        internal
        returns (uint64 sequence)
    {
        (uint256 dispensation,) = WORMHOLE_RELAYER.quoteEVMDeliveryPrice(wormholeChainId, 0, gasLimit); // Get a quote for the cost of gas for delivery
        require(address(this).balance >= dispensation, "Insufficient ETH for wormhole relayer fee");
        sequence = WORMHOLE_RELAYER.sendPayloadToEvm{
            value: dispensation
        }(wormholeChainId, address(this), payload, 0, gasLimit); // Send message via Wormhole relayer
    }

    /**
     * @notice Validates that a message came from the corresponding tribunal on another chain
     * @dev Checks that the emitter address matches this contract's address (deterministic across chains)
     */
    function _validateTribunalAddress(address emitter) internal view {
        require(emitter == address(this), "Message not from corresponding tribunal");
    }

    // ========================================================================
    // ============ FILL CHAIN: Single Message Operations =====================
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
        (dispensation,) = WORMHOLE_RELAYER.quoteEVMDeliveryPrice(WormholeMappings.toWormholeId(chainId), 0, GAS_LIMIT);
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

        message = abi.encodePacked(uint8(MessagePackingType.SINGLE_SEND), message); // Prepend message type for routing on claim chain

        uint16 wormholeChainId = WormholeMappings.toWormholeId(chainId); // Convert chainId to Wormhole format

        _sendViaRelayer(wormholeChainId, message, GAS_LIMIT); // Send message via Wormhole relayer
    }

    /**
     * @notice Publishes a single message via Wormhole core for user self-relay (SINGLE_POST)
     * @dev Uses wormhole.publishMessage() - user must relay VAA to claim chain themselves
     * @dev Includes all data needed to process the message in the payload itself for filler convenience + we already have in execution context
     */
    function _post(
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        bytes32 claimant,
        uint256[] memory claimAmounts
    ) internal refundExcessEth returns (uint64 sequence) {
        bytes memory message = Message.encode(
            compact, sponsorSignature, allocatorSignature, mandateHash, claimant, claimAmounts
        );

        sequence = _publishMessage(uint32(MessagePackingType.SINGLE_POST), message); // Publish message via Wormhole core
    }

    // ========================================================================
    // ============ FILL CHAIN: Batch Operations ==============================
    // ========================================================================

    /**
     * @notice Sends a batch of full message data to a single chain via relayer (BATCH_SEND)
     * @dev Public entry point - calls _batchSend() then refunds excess ETH
     */
    function batchSend(uint256 chainId, TheCompactBatchClaim[] calldata messages, uint256 gasLimit)
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
    function _batchSend(uint256 chainId, TheCompactBatchClaim[] calldata messages, uint256 gasLimit)
        internal
        virtual
        returns (uint64 sequence)
    {
        // Validate each claim hash exists in dispositions
        unchecked {
            for (uint256 i = 0; i < messages.length; ++i) {
                (bytes32 claimHash,) = messages[i].toClaimHashAndTypehash();
                require(this.filled(claimHash) != address(0), "Claim not found in dispositions");
            }
        }

        bytes memory encodedBatch = Message.encodeBatchSend(messages);

        encodedBatch = abi.encodePacked(uint8(MessagePackingType.BATCH_SEND), encodedBatch); // Prepend message type for routing on claim chain

        require(encodedBatch.length <= MAX_MESSAGE_SIZE, "Message exceeds max size"); // Enforce max message size

        uint16 wormholeChainId = WormholeMappings.toWormholeId(chainId); // Convert chainId to Wormhole format

        sequence = _sendViaRelayer(wormholeChainId, encodedBatch, gasLimit); // Send message via Wormhole relayer
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
    //TODO add exact out here with scaling factor and fix bytes32 / address mismatch
    function _batchPost(uint256 chainId, bytes32[] memory claimHashes) internal virtual returns (uint64 sequence) {
        bytes32[] memory claimants = new bytes32[](claimHashes.length);

        for (uint256 i = 0; i < claimHashes.length; i++) {
            //TODO: need to convert address to bytes32 before assigning but will fix once mappings are updated
            claimants[i] = bytes32(uint256(uint160(this.filled(claimHashes[i])))); // Convert address to bytes32 before assigning

        }

        bytes memory encodedBatch = Message.encodeBatchPost(claimants, claimHashes); // Encode the batch of claim hashes

        require(encodedBatch.length <= MAX_MESSAGE_SIZE, "Message exceeds max size"); // Enforce max message size

        sequence = _publishMessage(uint32(MessagePackingType.BATCH_POST), encodedBatch); // Publish message via Wormhole core
    }

    /**
     * @notice Posts batches of claim hashes to multiple chains via core (multichain BATCH_POST)
     * @dev Loops through chains calling _batchPost(), refunds once at the end
     * @return sequences Array of Wormhole message sequence numbers
     */
    function batchMultichainPost(BatchPost[] calldata batches)
        public
        payable
        virtual
        refundExcessEth
        returns (uint64[] memory sequences)
    {
        sequences = new uint64[](batches.length);
        unchecked {
            for (uint256 i = 0; i < batches.length; ++i) {
                sequences[i] = _batchPost(batches[i].chainId, batches[i].claimHashes);
            }
        }
    }

    /**
     * @notice Sends batches of full message data to multiple chains via relayer (multichain BATCH_SEND)
     * @dev Loops through chains calling _batchSend(), refunds once at the end
     */
    function batchMultichainSend(BatchSend[] calldata batches, uint256[] calldata gasLimits)
        public
        payable
        virtual
        refundExcessEth
        returns (uint64[] memory sequences)
    {
        require(batches.length == gasLimits.length, "Batches and gasLimits length mismatch");
        sequences = new uint64[](batches.length);
        unchecked {
            for (uint256 i = 0; i < batches.length; ++i) {
                sequences[i] = _batchSend(batches[i].chainId, batches[i].messages, gasLimits[i]);
            }
        }
    }

    // ========================================================================
    // ============ CLAIM CHAIN: Self Relayed Functions =======================
    // ========================================================================

    /**
     * @notice Receives and processes a single POST message relayed by user via VAA
     * @dev Handles SINGLE_POST message type via user self-relay with VAA
     * @param encodedVaa The encoded VAA from Wormhole
     * @param additionalData The full TheCompactBatchClaim needed to process the claim
     * @return sequence The Wormhole message sequence number
     */
    function receiveSinglePost(bytes memory encodedVaa, TheCompactBatchClaim calldata additionalData)
        public
        payable
        returns (uint64 sequence)
    {
        // Parse and validate VAA
        (IWormhole.VM memory vm, uint64 seq) = _parseAndValidateVAA(encodedVaa, MessagePackingType.SINGLE_POST);
        sequence = seq;

        // Extract claim hash from payload
        bytes32 claimHash = bytes32(vm.payload);

        // Process the claim
        _receiveSinglePost(claimHash, additionalData);
    }

    /**
     * @notice Receives and processes a batch POST message relayed by user via VAA
     * @dev Handles BATCH_POST message type via user self-relay with VAA
     * @param encodedVaa The encoded VAA from Wormhole
     * @param additionalData Array of full TheCompactBatchClaim needed to process each claim
     * @return sequence The Wormhole message sequence number
     */
    function receiveBatchPost(bytes memory encodedVaa, TheCompactBatchClaim[] calldata additionalData)
        public
        payable
        returns (uint64 sequence)
    {
        // Parse and validate VAA
        (IWormhole.VM memory vm, uint64 seq) = _parseAndValidateVAA(encodedVaa, MessagePackingType.BATCH_POST);
        sequence = seq;

        // Decode batch from payload
        (bytes32[] memory claimants, bytes32[] memory claimHashes) = Message.decodeBatchPost(vm.payload);

        // Process the batch
        _receiveBatchPost(claimants, claimHashes, additionalData);
    }

    /**
     * @notice Internal handler for single POST messages
     * @dev TODO: Verify claim hash and call _sendClaim()
     */
    function _receiveSinglePost(bytes32 claimHash, TheCompactBatchClaim calldata data) internal {
        // TODO: Compute claim hash from data and verify it matches claimHash (might not need this because self relaying)
        // TODO: Call _sendClaim() with decoded data
    }

    /**
     * @notice Internal handler for batch POST messages
     * @dev TODO: Verify claim hashes and call _sendClaim() for each
     */
    function _receiveBatchPost(bytes32[] memory claimants, bytes32[] memory claimHashes, TheCompactBatchClaim[] calldata data)
        internal
    {
        // TODO: For each claim, compute hash from data and verify it matches
        // TODO: Call _sendClaim() for each verified claim
    }

    /**
     * @notice Shared internal function to parse and validate VAA
     * @dev Extracts common validation logic for both single and batch POST receivers
     * @return vm The parsed Wormhole VM message
     * @return sequence The message sequence number
     */
    function _parseAndValidateVAA(bytes memory encodedVaa, MessagePackingType expectedType)
        internal
        returns (IWormhole.VM memory vm, uint64 sequence)
    {
        // Parse and verify the VAA
        bool valid;
        string memory reason;
        (vm, valid, reason) = WORMHOLE.parseAndVerifyVM(encodedVaa);
        require(valid, reason);

        // Validate tribunal address
        _validateTribunalAddress(address(uint160(uint256(vm.emitterAddress))));

        // Verify message type matches expected
        require(MessagePackingType(vm.nonce) == expectedType, "Invalid message type");

        sequence = vm.sequence;
    }

    // ========================================================================
    // ============ CLAIM CHAIN: Relayed Functions ============================
    // ========================================================================

    /**
     * @notice Receives and processes SEND messages delivered automatically by Wormhole relayer
     * @dev Handles SINGLE_SEND and BATCH_SEND message types via automatic relay
     * @dev Message authentication is guaranteed by the Wormhole relayer before reaching this function
     * @dev See "lib/wormhole-solidity-sdk/src/interfaces/IWormholeReceiver.sol" for interface details
     */
    function receiveWormholeMessages(
        bytes calldata payload,
        bytes[] memory additionalMessages,
        bytes32 sourceAddress,
        uint16 sourceChain,
        bytes32 deliveryHash
    ) external payable override {
        require(msg.sender == address(WORMHOLE_RELAYER), "Only the Wormhole relayer can call this function");

        _validateTribunalAddress(address(uint160(uint256(sourceAddress))));

        // Check first byte for MessagePackingType
        require(payload.length > 0, "Empty payload");
        MessagePackingType messageType = MessagePackingType(uint8(payload[0]));

        // Dispatch based on message type
        if (messageType == MessagePackingType.SINGLE_SEND) {
            _receiveSingleSend(payload[1:]);
        } else if (messageType == MessagePackingType.BATCH_SEND) {
            _receiveBatchSend(payload[1:]);
        } else {
            revert("Unsupported message type for relayer delivery");
        }
    }

    /**
     * @notice Internal handler for SINGLE_SEND messages
     * @dev Decodes and processes a single claim message
     */
    function _receiveSingleSend(bytes calldata payload) internal {
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
     * @notice Internal handler for BATCH_SEND messages
     * @dev Decodes and processes a batch of claim messages
     */
    function _receiveBatchSend(bytes calldata payload) internal {
        // Decode the batch
        TheCompactBatchClaim[] memory claims = Message.decodeBatchSend(payload);

        // Process each message in the batch
        unchecked {
            for (uint256 i = 0; i < claims.length; ++i) {
                TheCompactBatchClaim memory claim = claims[i];
                _sendClaim(
                    claim.sponsor,
                    claim.nonce,
                    claim.expires,
                    claim.allocatorData,
                    claim.sponsorSignature,
                    claim.witness,
                    claim.claims
                );
            }
        }
    }

    // ========================================================================
    // ============ CLAIM CHAIN: Shared Functions =============================
    // ========================================================================

    /**
     * @notice Internal function to construct and submit a batch claim to The Compact
     * @dev Constructs TheCompactBatchClaim payload and calls THE_COMPACT.batchClaim()
     * @dev Handles optional sponsor signature validation (checks for non-zero signature)
     */
    function _sendClaim(
        address sponsor,
        uint256 nonce,
        uint256 expires,
        bytes memory allocatorSignature,
        bytes memory rawSponsorSignature,
        bytes32 witness,
        BatchClaimComponent[] memory claims
    ) internal {
        // TODO: do we need to do this for allocatorSignature?
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
