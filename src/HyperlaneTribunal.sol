// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ITheCompactClaims} from "the-compact/src/interfaces/ITheCompactClaims.sol";
import {ClaimWithWitness} from "the-compact/src/types/Claims.sol";
import {Compact} from "the-compact/src/types/EIP712Types.sol";
import {Tribunal} from "tribunal/Tribunal.sol";

import {Router} from "hyperlane/contracts/client/Router.sol";

string constant WITNESS_TYPESTRING =
    "Mandate mandate)Mandate(uint256 chainId,address tribunal,address recipient,uint256 expires,address token,uint256 minimumAmount,uint256 baselinePriorityFee,uint256 scalingFactor,bytes32 salt)";

library Message {
    function encode(Tribunal.Claim calldata claim, bytes32 mandateHash, uint256 claimedAmount, address claimant)
        internal
        pure
        returns (bytes memory)
    {
        bytes calldata sponsorSignature = claim.sponsorSignature;
        bytes calldata allocatorSignature = claim.allocatorSignature;
        Tribunal.Compact calldata compact = claim.compact;

        require(sponsorSignature.length == 64 && allocatorSignature.length == 64, "invalid signature length");

        return abi.encodePacked(
            compact.arbiter,
            compact.sponsor,
            compact.nonce,
            compact.expires,
            compact.id,
            compact.amount,
            allocatorSignature,
            sponsorSignature,
            mandateHash,
            claimedAmount,
            claimant
        );
    }

    function decode(bytes calldata message)
        internal
        view
        returns (
            address sponsor,
            uint256 nonce,
            uint256 expires,
            uint256 id,
            uint256 allocatedAmount,
            bytes calldata allocatorSignature,
            bytes calldata sponsorSignature,
            bytes32 witness,
            uint256 claimedAmount,
            address claimant
        )
    {
        require(message.length == 380, "invalid message length");
        address arbiter = address(bytes20(message[0:20]));
        require(arbiter == address(this), "invalid arbiter");

        sponsor = address(bytes20(message[20:40]));
        nonce = uint256(bytes32(message[40:72]));
        expires = uint256(bytes32(message[72:104]));
        id = uint256(bytes32(message[104:136]));
        allocatedAmount = uint256(bytes32(message[136:168]));
        allocatorSignature = message[168:232];
        sponsorSignature = message[232:296];
        witness = bytes32(message[296:328]);
        claimedAmount = uint256(bytes32(message[328:360]));
        claimant = address(bytes20(message[360:380]));
    }
}

contract HyperlaneTribunal is Router, Tribunal {
    using Message for bytes;

    ITheCompactClaims public immutable theCompact;

    constructor(address _mailbox, address _theCompact) Router(_mailbox) {
        theCompact = ITheCompactClaims(_theCompact);
    }

    /**
     * @dev Process the directive for token claims
     * @param claim The claim parameters
     * @param mandateHash The derived mandate hash
     * @param claimant The recipient of claimed tokens on claim chain
     * @param claimAmount The amount to claim
     */
    function _processDirective(
        Tribunal.Claim calldata claim,
        bytes32 mandateHash,
        address claimant,
        uint256 claimAmount
    ) internal virtual override {
        uint32 chainId = uint32(claim.chainId);
        bytes memory message = Message.encode(claim, mandateHash, claimAmount, claimant);

        uint256 dispensation = _Router_quoteDispatch(chainId, message, "", address(hook));

        _Router_dispatch(chainId, dispensation, message, "", address(hook));
    }

    /**
     * @dev Derive the quote for the dispensation required for
     * the directive for token claims
     * @param claim The claim parameters
     * @param mandateHash The derived mandate hash
     * @param claimant The address of the claimant
     * @param claimAmount The amount to claim
     * @return dispensation The quoted dispensation amount
     */
    function _quoteDirective(Tribunal.Claim calldata claim, bytes32 mandateHash, address claimant, uint256 claimAmount)
        internal
        view
        virtual
        override
        returns (uint256 dispensation)
    {
        return _Router_quoteDispatch(
            uint32(claim.chainId), Message.encode(claim, mandateHash, claimAmount, claimant), "", address(hook)
        );
    }

    function _handle(
        uint32,
        /*origin*/
        bytes32,
        /*sender*/
        bytes calldata message
    ) internal override {
        (
            address sponsor,
            uint256 nonce,
            uint256 expires,
            uint256 id,
            uint256 allocatedAmount,
            bytes calldata allocatorSignature,
            bytes calldata sponsorSignature,
            bytes32 witness,
            uint256 claimedAmount,
            address claimant
        ) = message.decode();

        ClaimWithWitness memory claimPayload = ClaimWithWitness({
            witnessTypestring: WITNESS_TYPESTRING,
            witness: witness,
            allocatorSignature: allocatorSignature,
            sponsorSignature: sponsorSignature,
            sponsor: sponsor,
            nonce: nonce,
            expires: expires,
            id: id,
            allocatedAmount: allocatedAmount,
            amount: claimedAmount,
            claimant: claimant
        });

        theCompact.claim(claimPayload);
    }
}
