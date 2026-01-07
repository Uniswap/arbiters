// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {WormholeArbiter} from "../src/WormholeArbiter.sol";
import {WormholeMappings} from "../src/wormhole/WormholeMappings.sol";

interface ImmutableCreate2Factory {
    function safeCreate2(bytes32 salt, bytes calldata initializationCode)
        external
        payable
        returns (address deploymentAddress);

    function findCreate2Address(bytes32 salt, bytes calldata initCode) external view returns (address deploymentAddress);
}

contract WormholeArbiterScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        // get chain id and validate it is supported
        uint256 chainId = block.chainid;
        WormholeMappings.toWormholeId(chainId);

        // define salt and immutable create2 factory (throwaway salt for now)
        bytes32 salt = bytes32(0x00000000000000000000000000000000000000000000000feeddeadab0debeef);
        address immutableCreate2Factory = address(0x0000000000FFe8B47B3e2130213B802212439497);
        require(immutableCreate2Factory.code.length > 0, "ImmutableCreate2Factory not deployed");

        // Get predicted address
        bytes memory initCode = type(WormholeArbiter).creationCode;
        address predictedAddress = ImmutableCreate2Factory(immutableCreate2Factory).findCreate2Address(salt, initCode);

        // Check if already deployed
        if (predictedAddress.code.length > 0) {
            console.log("WormholeArbiter already deployed at:", predictedAddress);
            console.log("Skipping deployment...");
            vm.stopBroadcast();
            return;
        }

        // deploy the arbiter
        console.log("Deploying WormholeArbiter on chain:", chainId);
        console.log("Using salt:", vm.toString(salt));
        console.log("Predicted address:", predictedAddress);

        // deploy the arbiter using create2
        WormholeArbiter arbiter =
            WormholeArbiter(ImmutableCreate2Factory(immutableCreate2Factory).safeCreate2(salt, initCode));

        console.log("WormholeArbiter deployed at:", address(arbiter));

        // Verify address matches prediction
        require(address(arbiter) == predictedAddress, "Deployment address mismatch");

        vm.stopBroadcast();
    }
}

