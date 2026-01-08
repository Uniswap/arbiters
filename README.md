# Arbiters

This repository contains arbiter implementations for The Compact protocol. Arbiters relay filled claims from source chains to destination chains for settlement.

Currently, only the **Wormhole Arbiter** is compatible with The Compact V1.

---

## Wormhole Arbiter

Cross-chain arbiter using Wormhole messaging infrastructure.

### Overview

The Wormhole Arbiter facilitates cross-chain resource allocation by:
- Receiving dispatch callbacks from Tribunal when fills are completed
- Encoding and transmitting claim data to destination chains via Wormhole
- Receiving cross-chain messages and submitting claims to The Compact
- Supporting both automated relayer delivery (SEND) and filler self-relay (POST)

The system is deterministically deployed at the same address across all supported chains.

### High-Level Flow

1. Filler completes a fill on the source chain, triggering Tribunal's `dispatchCallback` to the arbiter
2. Arbiter encodes claim data and context into a compact message format
3. Cross-chain transmission:
   - **SEND**: Automatically relayed via Wormhole Executor
   - **POST**: Published to Wormhole Core for filler self-relay
4. Destination arbiter receives, validates, and submits the claim to The Compact

### Entry Points

#### Source Chain (Dispatch)

| Function | Description |
|----------|-------------|
| `dispatchCallback()` | Primary entry point called by Tribunal when a fill completes |
| `send()` | Single claim with automatic relay |
| `batchSend()` | Multiple claims to one chain |
| `multichainBatchSend()` | Multiple chains in one transaction |
| `post()` | Single claim, filler self-relays |
| `batchPost()` | Multiple claims to one chain  |
| `multichainBatchPost()` | Multiple chains in one transaction |

#### Destination Chain (Receive)

| Function | Description |
|----------|-------------|
| `executeVAAv1()` | Receives automatic SEND deliveries via Wormhole Executor |
| `receivePost()` | Receives self-relayed single POST messages |
| `receiveBatchPost()` | Receives self-relayed batch POST messages |

### Relay Mechanisms

**SEND** uses the Wormhole Executor framework for automatic delivery. Messages are relayed by Wormhole's relayer network with upfront payment for destination gas.

**POST** is self-relayed. Messages publish to Wormhole Core, then fillers fetch the VAA and submit to the destination chain. Lower cost but requires manual relay.

Both support batching (single chain or multichain) for gas optimization.

### VAA Data Contents

The amount of claim data encoded in the VAA varies by operation type:

| Operation | Claim Data in VAA | Filler Provides at Reception |
|-----------|-------------------|------------------------------|
| SEND | Full claim data | Nothing (relayer delivers) |
| POST | Full claim data | VAA only |
| BATCH_SEND | Full claim data for each claim | Nothing (relayer delivers) |
| BATCH_POST | Only claim hashes + scaling factors | Full claim data |

**SEND and BATCH_SEND**: All information required to submit the claim to The Compact is encoded in the VAA. The Wormhole relayer delivers the message and the arbiter decodes and submits directly.

**POST (single)**: Full claim data is included in the VAA despite being self-relayed. This is because single POSTs are typically dispatched within Tribunal's `dispatchCallback`, where the claim data is already available in calldata. Including it in the VAA avoids requiring the filler to re-provide it at reception.

**BATCH_POST**: Only claim hashes and scaling factors are encoded in the VAA (using bitmap compression for efficiency). The filler must provide the full claim data when calling `receiveBatchPost()`. This design prevents calldata duplication—without it, fillers would pay for the same claim data twice: once when posting to Wormhole and again when submitting to the destination chain. The arbiter verifies the provided claim data matches the hashes in the VAA before submitting to The Compact.

### Tribunal Integration

The arbiter validates fills with Tribunal before transmission:
- `TRIBUNAL.filled(claimHash)` confirms the fill and returns the claimant
- `TRIBUNAL.claimReductionScalingFactor(claimHash)` returns the scaling factor (1e18 = 100%)

### Supporting Components

| Component | Path | Purpose |
|-----------|------|---------|
| `BaseArbiter` | `src/abstracts/BaseArbiter.sol` | ETH refunds, claim hash derivation, Tribunal validation |
| `Message` | `src/libraries/Message.sol` | Encoding/decoding, bitmap compression for batches |
| `WormholeMappings` | `src/wormhole/WormholeMappings.sol` | Chain ID conversions, Wormhole contract addresses |

### Development

```bash
forge build      # Build contracts
forge test       # Run tests
forge fmt        # Format code
forge snapshot   # Gas snapshots
```
