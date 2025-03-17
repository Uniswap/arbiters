// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ITheCompactClaims} from "the-compact/src/interfaces/ITheCompactClaims.sol";
import {ClaimWithWitness, QualifiedClaimWithWitness} from "the-compact/src/types/Claims.sol";
import {Compact} from "the-compact/src/types/EIP712Types.sol";
import {Tribunal} from "tribunal/Tribunal.sol";

import {Router} from "hyperlane/contracts/client/Router.sol";

error InvalidChainId(uint256 chainId);

string constant WITNESS_TYPESTRING =
    "Mandate mandate)Mandate(uint256 chainId,address tribunal,address recipient,uint256 expires,address token,uint256 minimumAmount,uint256 baselinePriorityFee,uint256 scalingFactor,bytes32 salt)";

// keccak256("TargetBlock(bytes32 claimHash,uint256 targetBlock,uint256 maximumBlocksAfterTarget)")
bytes32 constant QUALIFICATION_TYPEHASH = 0x1abbddc6baae2ef20428b15d51b5e9b940797d8a967d0bf674fcfe1f8e71afc5;

library Message {
    function encode(
        Tribunal.Compact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        uint256 claimedAmount,
        address claimant,
        uint256 targetBlock,
        uint256 maximumBlocksAfterTarget
    ) internal pure returns (bytes memory) {
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
            claimant,
            targetBlock,
            maximumBlocksAfterTarget
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
            address claimant,
            uint256 targetBlock,
            uint256 maximumBlocksAfterTarget
        )
    {
        require(message.length == 444, "invalid message length");
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
        targetBlock = uint256(bytes32(message[380:412]));
        maximumBlocksAfterTarget = uint256(bytes32(message[412:444]));
    }
}

contract HyperlaneTribunal is Router, Tribunal {
    using Message for bytes;

    ITheCompactClaims public immutable theCompact;

    constructor(address _mailbox, address _theCompact) Router(_mailbox) {
        theCompact = ITheCompactClaims(_theCompact);
    }

    /**
     * @notice Process the mandated directive (i.e. trigger settlement).
     * @param chainId The claim chain where the resource lock is held.
     * @param compact The compact parameters.
     * @param sponsorSignature The signature of the sponsor.
     * @param allocatorSignature The signature of the allocator.
     * @param mandateHash The derived mandate hash.
     * @param claimant The recipient of claimed tokens on claim chain.
     * @param claimAmount The amount to claim.
     * @param targetBlock The targeted fill block, or 0 for no target block.
     * @param maximumBlocksAfterTarget Blocks after target that are still fillable.
     */
    function _processDirective(
        uint256 chainId,
        Tribunal.Compact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        address claimant,
        uint256 claimAmount,
        uint256 targetBlock,
        uint256 maximumBlocksAfterTarget
    ) internal virtual override {
        bytes memory message = Message.encode(
            compact,
            sponsorSignature,
            allocatorSignature,
            mandateHash,
            claimAmount,
            claimant,
            targetBlock,
            maximumBlocksAfterTarget
        );

        if (chainId > type(uint32).max) {
            revert InvalidChainId(chainId);
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
     * @param claimAmount The amount to claim.
     * @param targetBlock The targeted fill block, or 0 for no target block.
     * @param maximumBlocksAfterTarget Blocks after target that are still fillable.
     */
    function _quoteDirective(
        uint256 chainId,
        Tribunal.Compact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        address claimant,
        uint256 claimAmount,
        uint256 targetBlock,
        uint256 maximumBlocksAfterTarget
    ) internal view virtual override returns (uint256 dispensation) {
        return _Router_quoteDispatch(
            uint32(chainId),
            Message.encode(
                compact,
                sponsorSignature,
                allocatorSignature,
                mandateHash,
                claimAmount,
                claimant,
                targetBlock,
                maximumBlocksAfterTarget
            ),
            "",
            address(hook)
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
            bytes calldata rawSponsorSignature,
            bytes32 witness,
            uint256 claimedAmount,
            address claimant,
            uint256 targetBlock,
            uint256 maximumBlocksAfterTarget
        ) = message.decode();

        // Only assign sponsorSignature if provided signature has nonzero bytes
        bytes memory sponsorSignature;
        if (
            keccak256(rawSponsorSignature)
                != bytes32(0xad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5)
        ) {
            sponsorSignature = rawSponsorSignature;
        }

        // Use unqualified claim if no target block is provided
        if (targetBlock == uint256(0)) {
            ClaimWithWitness memory claimPayload = ClaimWithWitness({
                allocatorSignature: allocatorSignature,
                sponsorSignature: sponsorSignature,
                sponsor: sponsor,
                nonce: nonce,
                expires: expires,
                witness: witness,
                witnessTypestring: WITNESS_TYPESTRING,
                id: id,
                allocatedAmount: allocatedAmount,
                claimant: claimant,
                amount: claimedAmount
            });

            theCompact.claimAndWithdraw(claimPayload);
        } else {
            // Encode the qualification payload using the target block
            bytes memory qualificationPayload = abi.encode(targetBlock, maximumBlocksAfterTarget);

            QualifiedClaimWithWitness memory claimPayload = QualifiedClaimWithWitness({
                allocatorSignature: allocatorSignature,
                sponsorSignature: sponsorSignature,
                sponsor: sponsor,
                nonce: nonce,
                expires: expires,
                witness: witness,
                witnessTypestring: WITNESS_TYPESTRING,
                qualificationTypehash: QUALIFICATION_TYPEHASH,
                qualificationPayload: qualificationPayload,
                id: id,
                allocatedAmount: allocatedAmount,
                claimant: claimant,
                amount: claimedAmount
            });

            theCompact.claimAndWithdraw(claimPayload);
        }
    }
}
