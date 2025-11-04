// SPDX-License-Identifier: Apache 2
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {WormholeTribunal} from "../src/WormholeTribunal.sol";
import {WormholeRelayerBasicTest} from "test/helpers/WormholeRelayerTest.sol";
import {MockTheCompact} from "test/mocks/MockTheCompact.sol";
import {Mandate, Fill, Adjustment, RecipientCallback} from "../lib/tribunal/src/types/TribunalStructs.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";
import {ITribunal} from "../lib/tribunal/src/interfaces/ITribunal.sol";
import {MANDATE_TYPEHASH} from "../lib/tribunal/src/types/TribunalTypeHashes.sol";

/// @dev This test is modeled after lib/tribunal/test/TribunalFilledTest.t.sol
///      and is modeled after https://github.com/wormhole-foundation/hello-wormhole/blob/main/test/HelloWormhole.t.sol

contract WormholeTribunalTest is WormholeRelayerBasicTest {
    WormholeTribunal public tribunalSource;
    WormholeTribunal public tribunalTarget;

    function _assertTribunalSourceTargetEqual() internal view {
        assertEq(address(tribunalSource), address(tribunalTarget), "tribunalSource and tribunalTarget must be equal");
    }

    MockTheCompact public theCompactTarget;

    address public sponsor;
    uint256 public sponsorPrivateKey;
    address public allocator;
    uint256 public allocatorPrivateKey;
    address public adjuster;
    uint256 public adjusterPrivateKey;

    uint256[] public emptyPriceCurve;

    /// @notice Converts a standard ECDSA signature (v, r, s) to EIP-2098 compact format (64 bytes)
    /// @dev EIP-2098 compact signatures pack the v value into the s value's highest bit
    /// @param r The r component of the signature
    /// @param s The s component of the signature
    /// @param v The v component of the signature (27 or 28)
    /// @return compactSignature The 64-byte EIP-2098 compact signature
    function toEIP2098(bytes32 r, bytes32 s, uint8 v) internal pure returns (bytes memory) {
        // EIP-2098: vs = s | ((v - 27) << 255)
        // This packs the v value (0 or 1) into the highest bit of s
        bytes32 vs = s | bytes32(uint256(v - 27) << 255);
        return abi.encodePacked(r, vs);
    }

    function setUpSource() public override {
        // Deploy WormholeTribunal at deterministic address using CREATE2
        bytes32 salt = bytes32(uint256(0x1234));
        tribunalSource = new WormholeTribunal{salt: salt}();

        (sponsor, sponsorPrivateKey) = makeAddrAndKey("sponsor");
        (adjuster, adjusterPrivateKey) = makeAddrAndKey("adjuster");
        (allocator, allocatorPrivateKey) = makeAddrAndKey("allocator");

        emptyPriceCurve = new uint256[](0);

        // Set gas price configuration to avoid InvalidGasPrice error when forking
        // Set base fee to 0 and gas price to a small positive value
        vm.fee(0);
        vm.txGasPrice(1 gwei);
    }

    function setUpTarget() public override {
        // Deploy WormholeTribunal at the SAME deterministic address using CREATE2
        bytes32 salt = bytes32(uint256(0x1234));
        tribunalTarget = new WormholeTribunal{salt: salt}();

        address theCompactAddress = address(0x00000000000000171ede64904551eeDF3C6C9788);
        deployCodeTo("MockTheCompact.sol:MockTheCompact", theCompactAddress);
        theCompactTarget = MockTheCompact(theCompactAddress);
    }

    function test_E2E_Basic() public {
        // Verify both tribunals are at the same address
        _assertTribunalSourceTargetEqual();

        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunalSource),
            expires: block.timestamp + 1000,
            fillToken: address(0), // Use native token
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipient: address(0xCAFE),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(sponsorPrivateKey, "sponsor signature");
        bytes memory sponsorSignature = toEIP2098(r1, s1, v1);

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(allocatorPrivateKey, "allocator signature");
        bytes memory allocatorSignature = toEIP2098(r2, s2, v2);

        // Make it a cross-chain fill to avoid needing to mock TheCompact
        // The arbiter must be the WormholeTribunal address because Message.decode() checks
        // that the arbiter in the message matches address(this) on the receiving tribunal
        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
            chainId: 42161, // Arbitrum (supported chain)
            compact: BatchCompact({
                arbiter: address(tribunalSource), // Same as tribunalTarget due to CREATE2
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: sponsorSignature,
            allocatorSignature: allocatorSignature
        });

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: vm.getBlockNumber(),
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunalSource.deriveFillHash(fill);

        // Build a Mandate struct to compute the hash properly
        Mandate memory mandateStruct = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandateStruct.fills[0] = fill;

        bytes32 mandateHash = tribunalSource.deriveMandateHash(mandateStruct);
        bytes32 claimHash = tribunalSource.deriveClaimHash(claim.compact, mandateHash);
        assertEq(tribunalSource.filled(claimHash), address(0));

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = commitments[0].amount;

        // The actual claimHash will be computed in _fill using the mandateHash from _deriveMandateHash
        // We need to compute it the same way for the adjustment signature
        // The mandate hash typehash should match MANDATE_TYPEHASH from TribunalTypeHashes.sol
        bytes32 actualMandateHash =
            keccak256(abi.encode(MANDATE_TYPEHASH, adjuster, keccak256(abi.encodePacked(fillHashes))));
        bytes32 actualClaimHash = tribunalSource.deriveClaimHash(claim.compact, actualMandateHash);

        //get quote amount for cross-chain fill using quote function
        uint256 quoteAmount = tribunalSource.quote(
            claim,
            fill,
            adjuster,
            adjustment,
            fillHashes,
            bytes32(uint256(uint160(address(this)))),
            adjustment.targetBlock
        );

        // Expect CrossChainFill event for cross-chain fills
        vm.expectEmit(true, true, true, true, address(tribunalSource));
        emit ITribunal.CrossChainFill(
            claim.chainId, sponsor, address(this), actualClaimHash, 1 ether, claimAmounts, adjustment.targetBlock
        );

        // Sign the adjustment with the actual claimHash that will be computed in _fill
        bytes32 adjustmentHash = keccak256(
            abi.encode(
                keccak256(
                    "Adjustment(bytes32 claimHash,uint256 fillIndex,uint256 targetBlock,uint256[] supplementalPriceCurve,bytes32 validityConditions)"
                ),
                actualClaimHash,
                adjustment.fillIndex,
                adjustment.targetBlock,
                keccak256(abi.encodePacked(adjustment.supplementalPriceCurve)),
                adjustment.validityConditions
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Tribunal"),
                keccak256("1"),
                block.chainid,
                address(tribunalSource)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, adjustmentHash));
        (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(adjusterPrivateKey, digest);
        bytes memory adjustmentSignature = abi.encodePacked(r3, s3, v3);

        vm.recordLogs(); // record logs for the relayer to pick up

        tribunalSource.fill{
            value: quoteAmount + 1 ether
        }(
            claim,
            fill,
            adjuster,
            adjustment,
            adjustmentSignature,
            fillHashes,
            bytes32(uint256(uint160(address(this)))),
            0
        );
        assertEq(tribunalSource.filled(actualClaimHash), address(this));

        performDelivery(true); // Enable debug logging

        vm.selectFork(targetFork);

        assertEq(theCompactTarget.latestClaimHash(), actualClaimHash);
    }
}
