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
import {Message} from "./libraries/Message.sol";
import {WITNESS_TYPESTRING} from "tribunal/types/TribunalTypeHashes.sol";

//hyperlane imports
import {Router} from "hyperlane/contracts/client/Router.sol";

error InvalidChainId(uint256 chainId);

contract HyperlaneTribunal is Router, Tribunal {
    using Message for bytes;

    constructor(address _mailbox) Router(_mailbox) {}

    /**
     * @notice Process the mandated directive (i.e. trigger settlement).
     * @param chainId The claim chain where the resource lock is held.
     * @param compact The compact parameters.
     * @param sponsorSignature The signature of the sponsor.
     * @param allocatorSignature The signature of the allocator.
     * @param mandateHash The derived mandate hash.
     * @param claimant The recipient of claimed tokens on claim chain.
     * @param claimAmounts The amounts to claim.
     */
    function _processDirective(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        bytes32 claimant,
        uint256[] memory claimAmounts,
        uint256 //unused target block
    ) internal virtual override {
        bytes memory message =
            Message.encode(compact, sponsorSignature, allocatorSignature, mandateHash, claimant, claimAmounts);

        if (chainId > type(uint32).max) {
            revert InvalidChainId();
        }

        uint32 downcastedChainId = uint32(chainId);

        uint256 dispensation = _Router_quoteDispatch(downcastedChainId, message, "", address(hook));

        _Router_dispatch(downcastedChainId, dispensation, message, "", address(hook));
    }

    /**
     * @dev Derive the quote for the dispensation required for
     * the directive for token claims.
     * @param chainId The claim chain where the resource lock is held.
     * @param compact The compact parameters.
     * @param sponsorSignature The signature of the sponsor.
     * @param allocatorSignature The signature of the allocator.
     * @param mandateHash The derived mandate hash.
     * @param claimant The recipient of claimed tokens on claim chain.
     * @param claimAmounts The amounts to claim.
     */
    function _quoteDirective(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        bytes32 claimant,
        uint256[] memory claimAmounts,
        uint256 //unused target block
    ) internal view virtual override returns (uint256 dispensation) {
        return _Router_quoteDispatch(
            uint32(chainId),
            Message.encode(compact, sponsorSignature, allocatorSignature, mandateHash, claimant, claimAmounts),
            "",
            address(hook)
        );
    }

    function _handle(
        uint32,
        /*origin*/
        bytes32 sender,
        bytes calldata message
    )
        internal
        override
    {
        // check to make sure the message is from the corresponding tribunal
        require(address(uint160(uint256(sender))) == address(this), "Message not from corresponding tribunal");

        // decode the message
        (
            address sponsor,
            uint256 nonce,
            uint256 expires,
            bytes calldata allocatorSignature,
            bytes calldata rawSponsorSignature,
            bytes32 witness,
            BatchClaimComponent[] memory claims
        ) = message.decode();

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
