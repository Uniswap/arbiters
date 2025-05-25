pragma solidity ^0.8.0;

import "the-compact/test/TheCompact.t.sol";
import {HyperlaneTribunal, WITNESS_TYPESTRING} from "../src/HyperlaneTribunal.sol";

import {MockMailbox} from "hyperlane/contracts/mock/MockMailbox.sol";
import {TypeCasts} from "hyperlane/contracts/libs/TypeCasts.sol";
import {Tribunal} from "tribunal/Tribunal.sol";

contract HyperlaneTribunalTest is TheCompactTest {
    using TypeCasts for address;

    uint32 origin = uint32(block.chainid); // match the compact chain id
    uint32 destination = 2;

    MockMailbox originMailbox;
    MockMailbox destinationMailbox;

    HyperlaneTribunal originTribunal;
    HyperlaneTribunal destinationTribunal;

    uint256 fillerPrivateKey;
    address filler;

    function hyperlane_tribunal_setup() public {
        originMailbox = new MockMailbox(origin);
        destinationMailbox = new MockMailbox(destination);

        originMailbox.addRemoteMailbox(destination, destinationMailbox);
        destinationMailbox.addRemoteMailbox(origin, originMailbox);

        originTribunal = new HyperlaneTribunal(
            address(originMailbox),
            address(theCompact)
        );
        destinationTribunal = new HyperlaneTribunal(
            address(destinationMailbox),
            address(theCompact)
        );

        originTribunal.enrollRemoteRouter(
            destination,
            address(destinationTribunal).addressToBytes32()
        );
        destinationTribunal.enrollRemoteRouter(
            origin,
            address(originTribunal).addressToBytes32()
        );

        (filler, fillerPrivateKey) = makeAddrAndKey("filler");
        vm.deal(filler, 1e18);
    }

    function test_hyperlane_tribunal_claimWithWitness() public {
        hyperlane_tribunal_setup();

        ResetPeriod resetPeriod = ResetPeriod.TenMinutes;
        Scope scope = Scope.Multichain;
        uint256 amount = 1e18;
        uint256 nonce = 0;
        uint256 expires = block.timestamp + 1000;
        address claimant = 0x1111111111111111111111111111111111111111;
        address arbiter = address(originTribunal);

        vm.prank(allocator);
        theCompact.__registerAllocator(allocator, "");

        vm.prank(swapper);
        uint256 id = theCompact.deposit{value: amount}(
            allocator,
            resetPeriod,
            scope,
            swapper
        );
        assertEq(theCompact.balanceOf(swapper, id), amount);

        address token = address(0);
        uint256 minimumAmount = amount;
        uint256 baselinePriorityFee = 0;
        uint256 scalingFactor = 0;
        uint256[] memory decayCurve = new uint256[](0);
        bytes32 salt = bytes32(0);

        Tribunal.Mandate memory mandate = Tribunal.Mandate(
            claimant,
            expires,
            token,
            minimumAmount,
            baselinePriorityFee,
            scalingFactor,
            decayCurve,
            salt
        );

        vm.chainId(destination);
        bytes32 mandateHash = destinationTribunal.deriveMandateHash(mandate);
        vm.chainId(origin);

        Tribunal.Compact memory compact = Tribunal.Compact(
            arbiter,
            swapper,
            nonce,
            expires,
            id,
            amount
        );

        bytes32 claimHash = destinationTribunal.deriveClaimHash(
            compact,
            mandateHash
        );

        bytes32 digest = keccak256(
            abi.encodePacked(
                bytes2(0x1901),
                theCompact.DOMAIN_SEPARATOR(),
                claimHash
            )
        );

        (bytes32 r, bytes32 vs) = vm.signCompact(swapperPrivateKey, digest);
        bytes memory sponsorSignature = abi.encodePacked(r, vs);

        (r, vs) = vm.signCompact(allocatorPrivateKey, digest);
        bytes memory allocatorSignature = abi.encodePacked(r, vs);

        Tribunal.Claim memory claim = Tribunal.Claim(
            origin,
            compact,
            sponsorSignature,
            allocatorSignature
        );

        vm.chainId(destination);
        vm.startPrank(filler);
        destinationTribunal.fill{value: amount}(claim, mandate, filler);
        vm.stopPrank();

        vm.chainId(origin);
        originMailbox.processNextInboundMessage();

        assertEq(theCompact.balanceOf(swapper, id), 0);
        assertEq(theCompact.balanceOf(claimant, id), 0);
        assertEq(address(theCompact).balance, 0);
        assertEq(address(claimant).balance, minimumAmount);
        assertEq(address(filler).balance, amount);
    }
}
