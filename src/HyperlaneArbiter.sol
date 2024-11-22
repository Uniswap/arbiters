// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {TheCompact} from "the-compact/src/TheCompact.sol";
import {ClaimWithWitness} from "the-compact/src/types/Claims.sol";
import {Compact} from "the-compact/src/types/EIP712Types.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Router} from "hyperlane/contracts/client/Router.sol";

struct Intent {
    uint256 fee;
    uint32 chainId;
    address token;
    address recipient;
    uint256 amount;
}

string constant TYPESTRING = "Intent(uint256 fee,uint32 chainId,address token,address recipient,uint256 amount)";
bytes32 constant TYPEHASH = keccak256(bytes(TYPESTRING));

string constant WITNESS_TYPESTRING =
    "Intent intent)Intent(uint256 fee,uint32 chainId,address token,address recipient,uint256 amount)";

library Message {
    function encode(
        Compact calldata compact,
        bytes calldata allocatorSignature,
        bytes calldata sponsorSignature,
        bytes32 witness,
        uint256 fee,
        address filler
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            compact.arbiter,
            compact.sponsor,
            compact.nonce,
            compact.expires,
            compact.id,
            compact.amount,
            allocatorSignature,
            sponsorSignature,
            witness,
            fee,
            filler
        );
    }

    function decode(bytes calldata message)
        internal
        pure
        returns (
            // TODO: calldata
            Compact memory compact,
            bytes calldata allocatorSignature,
            bytes calldata sponsorSignature,
            bytes32 witness,
            uint256 fee,
            address filler
        )
    {
        assert(message.length == 380);
        compact = Compact({
            arbiter: address(bytes20(message[0:20])),
            sponsor: address(bytes20(message[20:40])),
            nonce: uint256(bytes32(message[40:72])),
            expires: uint256(bytes32(message[72:104])),
            id: uint256(bytes32(message[104:136])),
            amount: uint256(bytes32(message[136:168]))
        });
        allocatorSignature = message[168:232];
        sponsorSignature = message[232:296];
        witness = bytes32(message[296:328]);
        fee = uint256(bytes32(message[328:360]));
        filler = address(bytes20(message[360:380]));
    }
}

contract HyperlaneArbiter is Router {
    using Message for bytes;
    using SafeTransferLib for address;

    TheCompact public immutable theCompact;

    constructor(address _mailbox, address _theCompact) Router(_mailbox) {
        theCompact = TheCompact(_theCompact);
    }

    /**
     * @notice Fills a compact intent and dispatches the claim to the arbiter.
     * @dev msg.value is used to cover all hyperlane fees (relay, etc).
     * @param claimChain The chain ID of the claim.
     * @param compact The compact intent to fill.
     * @dev signatures must be compliant with https://eips.ethereum.org/EIPS/eip-2098
     * @param allocatorSignature The allocator's signature.
     * @param sponsorSignature The sponsor's signature.
     */
    function fill(
        uint32 claimChain,
        Compact calldata compact,
        Intent calldata intent,
        bytes calldata allocatorSignature,
        bytes calldata sponsorSignature
    ) external payable {
        require(block.chainid == intent.chainId, "invalid chain");

        // TODO: support Permit2 fills
        address filler = msg.sender;
        uint256 hyperlaneFee = msg.value;
        if (intent.token == address(0)) {
            Address.sendValue(payable(intent.recipient), intent.amount);
            hyperlaneFee -= intent.amount;
        } else {
            intent.token.safeTransferFrom(filler, intent.recipient, intent.amount);
        }

        _Router_dispatch(
            claimChain,
            hyperlaneFee,
            Message.encode(compact, allocatorSignature, sponsorSignature, hash(intent), intent.fee, filler),
            "",
            address(hook)
        );
    }

    function hash(Intent memory intent) public pure returns (bytes32) {
        return
            keccak256(abi.encode(TYPEHASH, intent.fee, intent.chainId, intent.token, intent.recipient, intent.amount));
    }

    function _handle(
        uint32,
        /*origin*/
        bytes32,
        /*sender*/
        bytes calldata message
    ) internal override {
        (
            Compact memory compact,
            bytes memory allocatorSignature,
            bytes memory sponsorSignature,
            bytes32 witness,
            uint256 fee,
            address filler
        ) = message.decode();

        ClaimWithWitness memory claimPayload = ClaimWithWitness({
            witnessTypestring: WITNESS_TYPESTRING,
            witness: witness,
            allocatorSignature: allocatorSignature,
            sponsorSignature: sponsorSignature,
            sponsor: compact.sponsor,
            nonce: compact.nonce,
            expires: compact.expires,
            id: compact.id,
            allocatedAmount: compact.amount,
            amount: fee,
            claimant: filler
        });

        theCompact.claim(claimPayload);
    }
}
