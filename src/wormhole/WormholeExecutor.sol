// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.19;

/**
 * @notice Copied from lib/wormhole-solidity-sdk/src/Executor/Integration.sol
 * @dev This file is adapted from the Wormhole SDK for our specific purposes
 */

import {ICoreBridge}               from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {IExecutor, IVaaV1Receiver} from "wormhole-sdk/interfaces/IExecutor.sol";
import {CoreBridgeLib}             from "wormhole-sdk/libraries/CoreBridge.sol";
import {RequestLib}                from "wormhole-sdk/Executor/Request.sol";
import {RelayInstructionLib}       from "wormhole-sdk/Executor/RelayInstruction.sol";
import {toUniversalAddress}        from "wormhole-sdk/Utils.sol";

//abstract base contracts for typical Executor integrations
//integrators should inherit from exactly one of:
// * ExecutorSend
// * ExecutorReceive
// * ExecutorSendReceive
//note: The Impl contracts are a nuisance to deal with the diamond inheritance pattern and
//      the "Base constructor arguments given twice" error that comes with it.

abstract contract ExecutorSharedBase {
  // forge-lint: disable-next-line(screaming-snake-case-immutable)
  ICoreBridge internal immutable _coreBridge;

  constructor(address coreBridge) {
    _coreBridge = ICoreBridge(coreBridge);
  }
}

abstract contract ExecutorSendImpl is ExecutorSharedBase {
  // forge-lint: disable-next-line(screaming-snake-case-immutable)
  IExecutor   internal immutable _executor;
  // forge-lint: disable-next-line(screaming-snake-case-immutable)
  uint16      internal immutable _chainId;

  constructor(address executor) {
    _executor = IExecutor(executor);
    _chainId = _coreBridge.chainId();
  }

  //added nonce parameter to allow for custom nonce
  function _publishAndRelay(
    bytes memory payload,
    uint8 consistencyLevel,
    uint256 totalCost, //must equal execution cost + Wormhole message fee for publishing!
    uint16 peerChain,
    address refundAddress,
    bytes calldata signedQuote,
    uint128 gasLimit,
    uint128 msgVal,
    uint32 nonce,
    bytes memory extraRelayInstructions
  ) internal returns (uint64 sequence) { unchecked {
    uint messageFee = _coreBridge.messageFee();
    sequence = _coreBridge.publishMessage{value: messageFee}(nonce, payload, consistencyLevel);

    bytes memory relayInstructions = RelayInstructionLib.encodeGas(gasLimit, msgVal);

    bytes32 peerAddress = bytes32(uint256(uint160(address(this))));

    //value calculation is unchecked because call will fail on underflow anyway
    _executor.requestExecution{value: totalCost - messageFee}(
      peerChain,
      peerAddress,
      refundAddress,
      signedQuote,
      RequestLib.encodeVaaMultiSigRequest(_chainId, peerAddress, sequence),
      relayInstructions
    );
  }}
}

abstract contract ExecutorReceiveImpl is ExecutorSharedBase, IVaaV1Receiver {
  constructor(address coreBridge) {}

  //default impl as safeguard - integrators should override this with an empty impl and perform
  //  appropriate check in their impl of _executeVaa instead, if they allow for non-zero msg.value
  function _executeVaaDefaultMsgValueCheck() internal virtual {
    require(msg.value == 0);
  }

  //WARNING: must correctly handle non-zero msg.value (since invoking function is payable)
  function _executeVaa(
    bytes calldata payload,
    uint32  timestamp,
    uint32  nonce,
    uint16  peerChain,
    bytes32 peerAddress,
    uint64  sequence,
    uint8   consistencyLevel
  ) internal virtual;

  // forge-lint: disable-next-line(mixed-case-function)
  function executeVAAv1(bytes calldata multiSigVaa) external payable virtual {
    _executeVaaDefaultMsgValueCheck();

    ( uint32  timestamp,
      uint32  nonce,
      uint16  emitterChainId,
      bytes32 emitterAddress,
      uint64  sequence,
      uint8   consistencyLevel,
      bytes calldata payload
    ) = CoreBridgeLib.decodeAndVerifyVaaCd(address(_coreBridge), multiSigVaa);

    // we check emitter address in arbiter side in _executeVaa function
    
    _executeVaa(
      payload,
      timestamp,
      nonce,
      emitterChainId,
      emitterAddress,
      sequence,
      consistencyLevel
    );
  }
}

abstract contract ExecutorSend is ExecutorSharedBase, ExecutorSendImpl {
  constructor(address coreBridge, address executor)
    ExecutorSharedBase(coreBridge)
    ExecutorSendImpl(executor)
  {}
}

abstract contract ExecutorReceive is ExecutorSharedBase, ExecutorReceiveImpl {
  constructor(address coreBridge)
    ExecutorSharedBase(coreBridge)
    ExecutorReceiveImpl(coreBridge)
  {}
}

abstract contract ExecutorSendReceive is ExecutorSharedBase, ExecutorSendImpl, ExecutorReceiveImpl {
  constructor(address coreBridge, address executor)
    ExecutorSendImpl(executor)
    ExecutorReceiveImpl(coreBridge)
    ExecutorSharedBase(coreBridge) {}
}
