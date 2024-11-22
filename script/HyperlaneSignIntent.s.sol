// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {Compact} from "the-compact/src/types/EIP712Types.sol";
import {HyperlaneArbiter, Intent} from "src/HyperlaneArbiter.sol";

contract HyperlaneSignIntent is Script {
    HyperlaneArbiter destinationArbiter;
    uint32 destination;

    uint32 origin;
    address arbiter;
    address allocator;
    address sponsor;
    bytes32 domainSeparator;

    uint256 sponsorPrivateKey;
    uint256 allocatorPrivateKey;

    uint256 id;

    function setUp() public {
        // origin commitments
        arbiter = vm.envAddress("ARBITER_ONE");
        origin = uint32(vm.envUint("DOMAIN_ONE"));
        domainSeparator = vm.envBytes32("DOMAIN_ONE_SEPARATOR");
        allocator = vm.envAddress("DEFAULT_ALLOCATOR");
        sponsor = vm.envAddress("DEFAULT_SPONSOR");
        id = vm.envUint("DEFAULT_ID");

        sponsorPrivateKey = vm.envUint("SPONSOR_PRIVATE_KEY");
        allocatorPrivateKey = vm.envUint("ALLOCATOR_PRIVATE_KEY");

        // destination fill interface
        address _destinationArbiter = vm.envAddress("ARBITER_TWO");
        destination = uint32(vm.envUint("DOMAIN_TWO"));
        destinationArbiter = HyperlaneArbiter(_destinationArbiter);
    }

    function run() public {
        uint256 amount = 1e18;
        address token = address(0x0); // native value
        uint256 nonce = 0;
        uint256 expires = block.timestamp + 1000;
        uint256 fee = amount;
        uint32 chainId = destination;

        Intent memory intent = Intent(fee, chainId, address(token), sponsor, amount);
        Compact memory compact = Compact(arbiter, sponsor, nonce, expires, id, amount);

        bytes32 witness = destinationArbiter.hash(intent);

        bytes32 claimHash = keccak256(
            abi.encode(
                keccak256(
                    "Compact(address arbiter,address sponsor,uint256 nonce,uint256 expires,uint256 id,uint256 amount,Intent intent)Intent(uint256 fee,uint32 chainId,address token,address recipient,uint256 amount)"
                ),
                arbiter,
                sponsor,
                nonce,
                expires,
                id,
                amount,
                witness
            )
        );

        bytes32 digest = keccak256(abi.encodePacked(bytes2(0x1901), domainSeparator, claimHash));

        (bytes32 r, bytes32 vs) = vm.signCompact(sponsorPrivateKey, digest);
        bytes memory sponsorSignature = abi.encodePacked(r, vs);

        (r, vs) = vm.signCompact(allocatorPrivateKey, digest);
        bytes memory allocatorSignature = abi.encodePacked(r, vs);

        vm.startBroadcast();
        destinationArbiter.fill{value: amount}(origin, compact, intent, allocatorSignature, sponsorSignature);
        vm.stopBroadcast();
    }
}
