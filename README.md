# Arbiters
Repository for developing and testing arbiters and associated standards for [The Compact](https://github.com/Uniswap/the-compact).

## Overview
Arbiters are tasked with processing claims against The Compact, and interact with it via the [Claims Interface](https://github.com/Uniswap/the-compact/blob/main/src/interfaces/ITheCompactClaims.sol#L56). The arbiter selects a claim method based on the type of Compact message signed by the sponsor and allocator and on the desired settlement behavior. To finalize a claim, _some_ actor must call into the arbiter, which will act on the input and translate it into their preferred claim method. The arbiter then must call the derived claim method on The Compact to finalize the claim process.

> There is also a [Core Interface](https://github.com/Uniswap/the-compact/blob/main/src/interfaces/ITheCompact.sol#L14) that depositors and allocators interact with, but this can be safely disregarded by arbiters (though some view functions may be useful depending on the context). Also note that The Compact will provide high-level safety guarantees around signatures, nonces, and expirations, which leaves arbiters free to focus on the safety guarantees around their respective cross-chain message protocol and other internal logic.

The claims interface exposes 96 endpoints, each of which takes a single struct argument. Most arbiters will select a struct that works for what they need, enabling them to disregard the other endpoints. A good starting choice for many varieties of arbiter would be the `ClaimWithWitness` struct:
```solidity
struct ClaimWithWitness {
    bytes allocatorSignature; // Authorization from the allocator.
    bytes sponsorSignature; // Authorization from the sponsor.
    address sponsor; // The account to source the tokens from.
    uint256 nonce; // A parameter to enforce replay protection, scoped to allocator.
    uint256 expires; // The time at which the claim expires.
    bytes32 witness; // Hash of the witness data.
    string witnessTypestring; // Witness typestring appended to existing typestring.
    uint256 id; // The token ID of the ERC6909 token to allocate.
    uint256 allocatedAmount; // The original allocated amount of ERC6909 tokens.
    address claimant; // The claim recipient; specified by the arbiter.
    uint256 amount; // The claimed token amount; specified by the arbiter.
}

```
To summarize the relevant components:
 - The first 5 elements (`allocatorSignature`, `sponsorSignature`, `sponsor`, `nonce`, & `expires`) will almost always be provided by the caller.
 - The `witness` element must match the hash of a single, arbitrary EIP-712 element; the simplest choice is to use a struct. The arbiter is responsible for accepting or deriving the necessary data contained by this element, validating it, and deriving the EIP-712 hash for it.
 - The `witnessTypestring` element will likely be a constant value supplied by the arbiter depending on the witness data it expects. It will be concatenated with the fixed components of the typestring by The Compact to derive a corresponding typehash. By way of example a given witness uses a struct of `Witness(uint256 witnessArgument)`, the supplied typestring would be `Witness witness)Witness(uint256 witnessArgument)`.
 - The `id` & `allocatedAmount` element represent the ID of the resource lock and the amount that the sponsor committed to. Note that the `id` parameter can be derived directly by knowing the underlying token, the allocator, the "reset period", and the "scope" of the resource lock; if the arbiter only supports a specific allocator, reset period, and scope, the underlying token alone would provide sufficient context to derive the ID.
 - The `claimant` and `amount` elements are chosen by the arbiter. The claimant (or recipient) will almost certainly be reported by the cross-chain message; the amount is also selected by the arbiter (though it must not exceed the allocated amount).

 A relatively minimal witness for an arbiter performing a cross-chain swap could include the following elements:
 - the destination chain
 - the required output token
 - the minimum output amount
 - the recipient address on the destination chain

The arbiter in this example would call one of these two endpoints on The Compact depending on whether the claimant should be receiving wrapped tokens or unwrapped equivalents:
```solidity
interface ITheCompactClaims {
    // ...
    function claim(ClaimWithWitness calldata claimPayload) external returns (bool);
    function claimAndWithdraw(ClaimWithWitness calldata claimPayload) external returns (bool);
    // ...
}
```

If multiple recipients are needed, the arbiter should utilize a `SplitClaimWithWitness` input argument; if multiple resource locks on a single chain are being claimed at once, a `BatchClaimWithWitness` should be used instead. See  [Section 4](https://github.com/Uniswap/the-compact/blob/main/README.md#4-submit-a-claim) of the README for a more detailed breakdown on advanced use-cases like qualified claims or multichain claims. Bear in mind that arbiters targeting cross-chain swaps should implement [EIP-7683](https://eips.ethereum.org/EIPS/eip-7683) if feasible or incorporate accompanying standards if their requirements differ from what EIP-7683 supports.

## Install & Usage
Ensure that [Foundry](https://book.getfoundry.sh/getting-started/installation) and [Supersim](https://supersim.pages.dev/getting-started/installation) are both installed.

To start Supersim and deploy The Compact (Version 0) to each chain, run:
```sh
$ ./bootstrap.sh
```

## Adding an Arbiter
Arbiter implementations should be placed into `src/[project]/arbiter/[name].sol` for the main arbiter interfacing with The Compact on the origin chain, `src/[project]/*/*.sol` for any ancillary contracts on the destination chain as well as project-specific bridge contracts, gateways, or other facilities. Then, associated deployments + tests should be structured as scripts so they can be incorporated into the Supersim test framework.