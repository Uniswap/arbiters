// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {TheCompact} from "the-compact/src/TheCompact.sol";
import {ClaimWithWitness} from "the-compact/src/types/Claims.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import {Router} from "hyperlane/contracts/client/Router.sol";

// witness data
struct Intent {
    // from sponsor allocated amount to claimant
    uint256 fee;

    uint32 chainId;
    address token;
    address recipient;
    uint256 amount;
}

struct Fill {
    address claimant;
    uint256 fee;
}

string constant TYPESTRING = "Intent(uint256 fee,uint32 chainId,address recipient,address token,uint256 amount)";
bytes32 constant TYPEHASH = keccak256(bytes(TYPESTRING));

contract HyperlaneArbiter is Router {
    using SafeTransferLib for address;

    TheCompact public immutable theCompact;

    mapping(bytes32 witness => Fill) public fills;

    constructor(address _mailbox, address _theCompact) Router(_mailbox) {
        theCompact = TheCompact(_theCompact);
    }

    function fill(
        uint32 claimChain,
        Intent calldata intent // adding discriminator
    ) external payable { // filler must pay for message dispatch
        require(block.chainid == intent.chainId, "invalid chain");

        // TODO: support Permit2 fills
        address claimant = msg.sender;
        intent.token.safeTransferFrom(claimant, intent.recipient, intent.amount);

        bytes32 witness = hash(intent);
        _dispatch(claimChain, abi.encodePacked(witness, intent.fee, claimant));
    }

    function hash(Intent calldata intent) public pure returns (bytes32) {
        return keccak256(abi.encode(
            TYPEHASH,
            intent.fee,
            intent.chainId,
            intent.recipient,
            intent.token,
            intent.amount
        ));
    }

    function _handle(uint32 /*origin*/, bytes32 /*sender*/, bytes calldata message) internal override {
        bytes32 witness = bytes32(message[0:32]);
        uint256 fee = uint256(bytes32(message[32:64]));
        address claimaint = address(bytes20(message[64:84]));

        require(fills[witness].claimant == address(0), "intent already filled");
        fills[witness] = Fill(claimaint, fee);
    }

    function claim(ClaimWithWitness calldata claimPayload) external {
        Fill storage witnessFill = fills[claimPayload.witness];
        require(witnessFill.fee == claimPayload.amount, "invalid claim amount");
        require(witnessFill.claimant == claimPayload.claimant, "invalid claimant");

        // assuming that the compact does
        // 1. sponsor signature verification
        // 2. replay protection
        // 3. expiration check
        theCompact.claim(claimPayload);
    }
}
