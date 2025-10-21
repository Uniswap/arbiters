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

    IWormholeRelayer public immutable wormholeRelayer;
    IWormhole public immutable wormhole;

    constructor() {
        wormholeRelayer = IWormholeRelayer(WormholeMappings.getWormholeRelayer(block.chainid));
        wormhole = IWormhole(WormholeMappings.getWormhole(block.chainid));
    }

    /**
     * @dev Dispatches a single message using the enshrined Wormhole relayer.
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
    ) internal virtual override {
        bytes memory message = Message.encode(
            compact,
            sponsorSignature,
            allocatorSignature,
            mandateHash,
            claimant,
            claimAmounts
        );

        uint16 wormholeChainId = WormholeMappings.toWormholeId(chainId);

        // Get a quote for the cost of gas for delivery
        (uint256 dispensation, ) = wormholeRelayer.quoteEVMDeliveryPrice(wormholeChainId, 0, GAS_LIMIT);

        wormholeRelayer.sendPayloadToEvm{value: dispensation}(
            wormholeChainId,
            address(this),
            message,
            0,
            GAS_LIMIT
        );
    }

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
     * @dev Receives a single message using the enshrined Wormhole relayer.
     * As this endpoint is only invoked by the enshrined Wormhole relayer,
     * message authentication is guaranteed before reaching this function.
     * See "lib/wormhole-solidity-sdk/src/interfaces/IWormholeReceiver.sol" for more information.
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