# Wormhole Arbiter

## Summary

Wormhole Arbiter is a cross-chain arbiter implementation for The Compact protocol that leverages Wormhole's messaging infrastructure to enable secure communication between fill chains and claim chains.

## Overview

The Wormhole Arbiter facilitates cross-chain resource allocation by:
- Receiving dispatch callbacks from Tribunal when fills are completed on one chain
- Encoding and transmitting claim data to destination chains via Wormhole
- Receiving and processing cross-chain messages to submit claims to The Compact
- Supporting both automated relayer delivery (SEND) and filler self-relay (POST) patterns

The system is designed to be deterministically deployed at the same address across all supported chains, enabling trustless message verification through address matching.

## High-Level Flow

1. **Initiation**: A filler completes a fill on the fill chain, triggering Tribunal's `dispatchCallback` to the Wormhole Arbiter
2. **Dispatch Encoding**: The arbiter encodes the claim data and context (allocator data, sponsor signature, scaling factors) into a compact message format
3. **Cross-Chain Transmission**:
   - **SEND operations**: Messages are automatically relayed via Wormhole Executor framework
   - **POST operations**: Messages are published to Wormhole core for filler self-relay
4. **Reception**: The destination chain's arbiter receives and validates the message
5. **Claim Submission**: The arbiter submits the claim to The Compact on the destination chain

## Main Components

### Entry Points for the Wormhole Arbiter

**Tribunal Entrypoint**

`dispatchCallback()` - `src/WormholeArbiter.sol:65`

Primary entry point called by Tribunal when a fill completes. Decodes context flags (SEND vs POST) and routes to `_send()` or `_post()`.

Context encodes:
- Allocator data and sponsor signature
- For SEND: Wormhole parameters (gasLimit, totalCost) and signed relayer quote
- For POST: Only signatures (no relayer parameters)

**SEND Operations (Automatic Relay via Wormhole Executor)**
- `send()` - Single claim with automatic delivery
- `batchSend()` - Multiple claims to one chain (max 5KB)
- `multichainBatchSend()` - Multiple chains in one transaction

**POST Operations (Self-Relay via Wormhole Core)**
- `post()` - Single claim, filler self-relays (lower cost, no relayer fees)
- `batchPost()` - Multiple claims to one chain (up to 120, bitmap encoding)
- `multichainBatchPost()` - Multiple chains in one transaction

**Receive Operations**
- `executeVAAv1()` - Public entrypoint in WormholeExecutor that calls `_executeVaa()` for automatic SEND message delivery
- `receivePost()` - Public entry for self-relayed single POST messages
- `receiveBatchPost()` - Public entry for self-relayed batch POST messages

### Supporting Components

**`BaseArbiter`** - `src/abstracts/BaseArbiter.sol`
- ETH refund mechanism, claim hash derivation (EIP-712), Tribunal validation

**`Message` Library** - `src/libraries/Message.sol`
- Encoding/decoding for SEND and POST contexts, bitmap compression for batches

## Relay Mechanisms

**SEND operations** use the Wormhole Executor framework for automatic delivery. Messages are relayed by Wormhole's relayer network with upfront payment for destination gas.

**POST operations** are self-relayed. Messages publish to Wormhole core, then fillers fetch the VAA and submit to the destination chain when convenient. Lower cost but requires manual relay.

Both support **batching** (single chain or multichain) for gas optimization.

## Tribunal Integration

Arbiter validates fills with Tribunal before transmission:
- `TRIBUNAL.filled(claimHash)` confirms the fill and returns claimant
- `TRIBUNAL.claimReductionScalingFactor(claimHash)` provides scaling factor (1e18 = 100%)

**Dispatch flow:**
1. Filler completes fill on Tribunal
2. Tribunal calls `arbiter.dispatchCallback()` with context (encoded operation type + parameters)
3. Arbiter routes to SEND or POST, validates, and transmits cross-chain
4. Destination arbiter receives and submits to The Compact

## Development

**Build**
```bash
forge build
```

**Test**
```bash
forge test
```

**Format**
```bash
forge fmt
```

**Gas Snapshots**
```bash
forge snapshot
```

