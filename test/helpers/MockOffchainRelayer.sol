// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

/**
 * @notice This file is a copy of lib/wormhole-solidity-sdk/src/testing/helpers/MockOffchainRelayer.sol
 * @dev Copied and optimized to avoid "stack too deep" errors.
 *
 * Original source: https://github.com/wormhole-foundation/wormhole-solidity-sdk
 *
 * Key optimizations:
 * - Extracted complex logic into separate internal functions
 * - Reduced number of local variables in critical functions
 * - Restructured loops to minimize stack usage
 */

import "forge-std/Vm.sol";
import "forge-std/console.sol";

import {toWormholeFormat, fromWormholeFormat} from "../../lib/wormhole-solidity-sdk/src/Utils.sol";
import {CCTPMessageLib} from "../../lib/wormhole-solidity-sdk/src/CCTPBase.sol";
import "../../lib/wormhole-solidity-sdk/src/interfaces/IWormholeRelayer.sol";
import "../../lib/wormhole-solidity-sdk/src/interfaces/IWormhole.sol";
import "../../lib/wormhole-solidity-sdk/src/libraries/BytesParsing.sol";

import {WormholeSimulator} from "../../lib/wormhole-solidity-sdk/src/testing/helpers/WormholeSimulator.sol";
import {CircleMessageTransmitterSimulator} from "../../lib/wormhole-solidity-sdk/src/testing/helpers/CircleCCTPSimulator.sol";
import "../../lib/wormhole-solidity-sdk/src/testing/helpers/DeliveryInstructionDecoder.sol";
import "../../lib/wormhole-solidity-sdk/src/testing/helpers/ExecutionParameters.sol";

using BytesParsing for bytes;

contract MockOffchainRelayer {

    uint16 chainIdOfWormholeAndGuardianUtilities;
    IWormhole relayerWormhole;
    WormholeSimulator relayerWormholeSimulator;
    CircleMessageTransmitterSimulator relayerCircleSimulator;

    // Taken from forge-std/Script.sol
    address private constant VM_ADDRESS =
        address(bytes20(uint160(uint256(keccak256("hevm cheat code")))));
    Vm public constant vm = Vm(VM_ADDRESS);

    mapping(uint16 => address) wormholeRelayerContracts;
    mapping(uint16 => uint256) forks;
    mapping(uint256 => uint16) chainIdFromFork;
    mapping(bytes32 => bytes[]) pastEncodedSignedVaas;
    mapping(bytes32 => bytes) pastEncodedDeliveryVAA;

    constructor(address _wormhole, address _wormholeSimulator, address _circleSimulator) {
        relayerWormhole = IWormhole(_wormhole);
        relayerWormholeSimulator = WormholeSimulator(_wormholeSimulator);
        relayerCircleSimulator = CircleMessageTransmitterSimulator(_circleSimulator);
        chainIdOfWormholeAndGuardianUtilities = relayerWormhole.chainId();
    }

    function getPastEncodedSignedVaas(
        uint16 chainId,
        uint64 deliveryVAASequence
    ) public view returns (bytes[] memory) {
        return
            pastEncodedSignedVaas[
                keccak256(abi.encodePacked(chainId, deliveryVAASequence))
            ];
    }

    function getPastDeliveryVAA(
        uint16 chainId,
        uint64 deliveryVAASequence
    ) public view returns (bytes memory) {
        return
            pastEncodedDeliveryVAA[
                keccak256(abi.encodePacked(chainId, deliveryVAASequence))
            ];
    }

    function registerChain(
        uint16 chainId,
        address wormholeRelayerContractAddress,
        uint256 fork
    ) public {
        wormholeRelayerContracts[chainId] = wormholeRelayerContractAddress;
        forks[chainId] = fork;
        chainIdFromFork[fork] = chainId;
    }

    function relay() public {
        relay(vm.getRecordedLogs());
    }

    function relay(Vm.Log[] memory logs, bool debugLogging) public {
        relay(logs, bytes(""), debugLogging);
    }

    function relay(Vm.Log[] memory logs) public {
        (logs, bytes(""), false);
    }

    function vaaKeyMatchesVAA(
        VaaKey memory vaaKey,
        bytes memory signedVaa
    ) internal view returns (bool) {
        IWormhole.VM memory parsedVaa = relayerWormhole.parseVM(signedVaa);
        return
            (vaaKey.chainId == parsedVaa.emitterChainId) &&
            (vaaKey.emitterAddress == parsedVaa.emitterAddress) &&
            (vaaKey.sequence == parsedVaa.sequence);
    }

    function cctpKeyMatchesCCTPMessage(
        CCTPMessageLib.CCTPKey memory cctpKey,
        CCTPMessageLib.CCTPMessage memory cctpMessage
    ) internal pure returns (bool) {
        (uint64 nonce,) = cctpMessage.message.asUint64(12);
        (uint32 domain,) = cctpMessage.message.asUint32(4);
        return
           nonce == cctpKey.nonce && domain == cctpKey.domain;
    }

    // Struct to reduce stack variables in relay function
    struct RelayContext {
        uint16 chainId;
        bytes[] encodedSignedVaas;
        CCTPMessageLib.CCTPMessage[] circleSignedMessages;
        IWormhole.VM[] parsed;
    }

    function relay(
        Vm.Log[] memory logs,
        bytes memory deliveryOverrides,
        bool debugLogging
    ) public {
        uint16 chainId = chainIdFromFork[vm.activeFork()];
        require(
            wormholeRelayerContracts[chainId] != address(0),
            "Chain not registered with MockOffchainRelayer"
        );

        RelayContext memory ctx;
        ctx.chainId = chainId;

        vm.selectFork(forks[chainIdOfWormholeAndGuardianUtilities]);

        // Fetch and sign VAAs
        ctx.encodedSignedVaas = _fetchAndSignVaas(logs, chainId, debugLogging);

        // Fetch and sign CCTP messages if available
        ctx.circleSignedMessages = _fetchAndSignCCTPMessages(logs, debugLogging);

        // Parse all VAAs
        ctx.parsed = _parseVaas(ctx.encodedSignedVaas);

        // Process each VAA for relay
        _processVaasForRelay(ctx, deliveryOverrides, debugLogging);

        vm.selectFork(forks[chainId]);
    }

    function _fetchAndSignVaas(
        Vm.Log[] memory logs,
        uint16 chainId,
        bool debugLogging
    ) internal returns (bytes[] memory) {
        Vm.Log[] memory entries = relayerWormholeSimulator
            .fetchWormholeMessageFromLog(logs);

        if (debugLogging) {
            console.log("Found %s wormhole messages in logs", entries.length);
        }

        bytes[] memory encodedSignedVaas = new bytes[](entries.length);
        for (uint256 i = 0; i < encodedSignedVaas.length; i++) {
            encodedSignedVaas[i] = relayerWormholeSimulator.fetchSignedMessageFromLogs(
                entries[i],
                chainId
            );
        }
        return encodedSignedVaas;
    }

    function _fetchAndSignCCTPMessages(
        Vm.Log[] memory logs,
        bool debugLogging
    ) internal returns (CCTPMessageLib.CCTPMessage[] memory) {
        bool checkCCTP = relayerCircleSimulator.valid();
        if (!checkCCTP) {
            return new CCTPMessageLib.CCTPMessage[](0);
        }

        Vm.Log[] memory cctpEntries = relayerCircleSimulator
            .fetchMessageTransmitterLogsFromLogs(logs);

        if (debugLogging) {
            console.log("Found %s circle messages in logs", cctpEntries.length);
        }

        CCTPMessageLib.CCTPMessage[] memory circleSignedMessages =
            new CCTPMessageLib.CCTPMessage[](cctpEntries.length);

        for (uint256 i = 0; i < cctpEntries.length; i++) {
            circleSignedMessages[i] = relayerCircleSimulator.fetchSignedMessageFromLog(
                cctpEntries[i]
            );
        }
        return circleSignedMessages;
    }

    function _parseVaas(bytes[] memory encodedSignedVaas)
        internal
        view
        returns (IWormhole.VM[] memory)
    {
        IWormhole.VM[] memory parsed = new IWormhole.VM[](encodedSignedVaas.length);
        for (uint16 i = 0; i < encodedSignedVaas.length; i++) {
            parsed[i] = relayerWormhole.parseVM(encodedSignedVaas[i]);
        }
        return parsed;
    }

    function _processVaasForRelay(
        RelayContext memory ctx,
        bytes memory deliveryOverrides,
        bool debugLogging
    ) internal {
        for (uint16 i = 0; i < ctx.encodedSignedVaas.length; i++) {
            if (debugLogging) {
                console.log(
                    "Found VAA from chain %s emitted from %s",
                    ctx.parsed[i].emitterChainId,
                    fromWormholeFormat(ctx.parsed[i].emitterAddress)
                );
            }

            if (
                ctx.parsed[i].emitterAddress ==
                toWormholeFormat(wormholeRelayerContracts[ctx.chainId]) &&
                (ctx.parsed[i].emitterChainId == ctx.chainId)
            ) {
                if (debugLogging) {
                    console.log("Relaying VAA to chain %s", ctx.chainId);
                }
                vm.selectFork(forks[chainIdOfWormholeAndGuardianUtilities]);
                genericRelay(
                    ctx.encodedSignedVaas[i],
                    ctx.encodedSignedVaas,
                    ctx.circleSignedMessages,
                    ctx.parsed[i],
                    deliveryOverrides
                );
            }
        }
    }

    function relay(bytes memory deliveryOverrides) public {
        relay(vm.getRecordedLogs(), deliveryOverrides, false);
    }

    function setInfo(
        uint16 chainId,
        uint64 deliveryVAASequence,
        bytes[] memory encodedSignedVaas,
        bytes memory encodedDeliveryVAA
    ) internal {
        bytes32 key = keccak256(abi.encodePacked(chainId, deliveryVAASequence));
        pastEncodedSignedVaas[key] = encodedSignedVaas;
        pastEncodedDeliveryVAA[key] = encodedDeliveryVAA;
    }

    function genericRelay(
        bytes memory encodedDeliveryVAA,
        bytes[] memory encodedSignedVaas,
        CCTPMessageLib.CCTPMessage[] memory cctpMessages,
        IWormhole.VM memory parsedDeliveryVAA,
        bytes memory deliveryOverrides
    ) internal {
        (uint8 payloadId, ) = parsedDeliveryVAA.payload.asUint8Unchecked(0);

        if (payloadId == 1) {
            _handleDeliveryInstruction(
                encodedDeliveryVAA,
                encodedSignedVaas,
                cctpMessages,
                parsedDeliveryVAA,
                deliveryOverrides
            );
        } else if (payloadId == 2) {
            _handleRedeliveryInstruction(
                parsedDeliveryVAA,
                deliveryOverrides
            );
        }
    }

    function _handleDeliveryInstruction(
        bytes memory encodedDeliveryVAA,
        bytes[] memory encodedSignedVaas,
        CCTPMessageLib.CCTPMessage[] memory cctpMessages,
        IWormhole.VM memory parsedDeliveryVAA,
        bytes memory deliveryOverrides
    ) internal {
        DeliveryInstruction memory instruction = decodeDeliveryInstruction(
            parsedDeliveryVAA.payload
        );

        bytes[] memory encodedSignedVaasToBeDelivered = _prepareVaasForDelivery(
            instruction,
            encodedSignedVaas,
            cctpMessages
        );

        EvmExecutionInfoV1 memory executionInfo = decodeEvmExecutionInfoV1(
            instruction.encodedExecutionInfo
        );

        uint256 budget = executionInfo.gasLimit *
            executionInfo.targetChainRefundPerGasUnused +
            instruction.requestedReceiverValue +
            instruction.extraReceiverValue;

        _executeDelivery(
            instruction.targetChain,
            encodedSignedVaasToBeDelivered,
            encodedDeliveryVAA,
            deliveryOverrides,
            budget
        );

        setInfo(
            parsedDeliveryVAA.emitterChainId,
            parsedDeliveryVAA.sequence,
            encodedSignedVaasToBeDelivered,
            encodedDeliveryVAA
        );
    }

    function _prepareVaasForDelivery(
        DeliveryInstruction memory instruction,
        bytes[] memory encodedSignedVaas,
        CCTPMessageLib.CCTPMessage[] memory cctpMessages
    ) internal view returns (bytes[] memory) {
        bytes[] memory encodedSignedVaasToBeDelivered = new bytes[](
            instruction.messageKeys.length
        );

        for (uint8 i = 0; i < instruction.messageKeys.length; i++) {
            if (instruction.messageKeys[i].keyType == 1) {
                // VaaKey
                encodedSignedVaasToBeDelivered[i] = _findMatchingVaa(
                    instruction.messageKeys[i].encodedKey,
                    encodedSignedVaas
                );
            } else if (instruction.messageKeys[i].keyType == 2) {
                // CCTP Key
                encodedSignedVaasToBeDelivered[i] = _findMatchingCCTPMessage(
                    instruction.messageKeys[i].encodedKey,
                    cctpMessages
                );
            }
        }

        return encodedSignedVaasToBeDelivered;
    }

    function _findMatchingVaa(
        bytes memory encodedKey,
        bytes[] memory encodedSignedVaas
    ) internal view returns (bytes memory) {
        (VaaKey memory vaaKey, ) = decodeVaaKey(encodedKey, 0);

        for (uint8 j = 0; j < encodedSignedVaas.length; j++) {
            if (vaaKeyMatchesVAA(vaaKey, encodedSignedVaas[j])) {
                return encodedSignedVaas[j];
            }
        }
        return bytes("");
    }

    function _findMatchingCCTPMessage(
        bytes memory encodedKey,
        CCTPMessageLib.CCTPMessage[] memory cctpMessages
    ) internal pure returns (bytes memory) {
        (CCTPMessageLib.CCTPKey memory key,) = decodeCCTPKey(encodedKey, 0);

        for (uint8 j = 0; j < cctpMessages.length; j++) {
            if (cctpKeyMatchesCCTPMessage(key, cctpMessages[j])) {
                return abi.encode(cctpMessages[j].message, cctpMessages[j].signature);
            }
        }
        return bytes("");
    }

    function _executeDelivery(
        uint16 targetChain,
        bytes[] memory encodedSignedVaasToBeDelivered,
        bytes memory encodedDeliveryVAA,
        bytes memory deliveryOverrides,
        uint256 budget
    ) internal {
        vm.selectFork(forks[targetChain]);
        vm.deal(address(this), budget);
        vm.recordLogs();

        IWormholeRelayerDelivery(wormholeRelayerContracts[targetChain])
            .deliver{value: budget}(
            encodedSignedVaasToBeDelivered,
            encodedDeliveryVAA,
            payable(address(this)),
            deliveryOverrides
        );
    }

    function _handleRedeliveryInstruction(
        IWormhole.VM memory parsedDeliveryVAA,
        bytes memory deliveryOverrides
    ) internal {
        RedeliveryInstruction memory instruction = decodeRedeliveryInstruction(
            parsedDeliveryVAA.payload
        );

        DeliveryOverride memory deliveryOverride = DeliveryOverride({
            newExecutionInfo: instruction.newEncodedExecutionInfo,
            newReceiverValue: instruction.newRequestedReceiverValue,
            redeliveryHash: parsedDeliveryVAA.hash
        });

        EvmExecutionInfoV1 memory executionInfo = decodeEvmExecutionInfoV1(
            instruction.newEncodedExecutionInfo
        );

        uint256 budget = executionInfo.gasLimit *
            executionInfo.targetChainRefundPerGasUnused +
            instruction.newRequestedReceiverValue;

        bytes memory oldEncodedDeliveryVAA = getPastDeliveryVAA(
            instruction.deliveryVaaKey.chainId,
            instruction.deliveryVaaKey.sequence
        );

        bytes[] memory oldEncodedSignedVaas = getPastEncodedSignedVaas(
            instruction.deliveryVaaKey.chainId,
            instruction.deliveryVaaKey.sequence
        );

        uint16 targetChain = decodeDeliveryInstruction(
            relayerWormhole.parseVM(oldEncodedDeliveryVAA).payload
        ).targetChain;

        vm.selectFork(forks[targetChain]);
        IWormholeRelayerDelivery(wormholeRelayerContracts[targetChain])
            .deliver{value: budget}(
            oldEncodedSignedVaas,
            oldEncodedDeliveryVAA,
            payable(address(this)),
            encode(deliveryOverride)
        );
    }

    receive() external payable {}
}
