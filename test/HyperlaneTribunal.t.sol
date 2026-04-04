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
        token.mint(filler, 1e18);

        vm.startPrank(filler);
        token.approve(address(destinationTribunal), 1e18);
        vm.stopPrank();
    }

    function test_hyperlane_tribunal_claimWithWitnessETH() public {
        hyperlane_tribunal_setup();

        ResetPeriod resetPeriod = ResetPeriod.TenMinutes;
        Scope scope = Scope.Multichain;
        uint256 amount = 1e18;
        uint256 nonce = 0;
        uint256 expires = block.timestamp + 1000;
        address claimant = 0x1111111111111111111111111111111111111111;
        address arbiter = address(originTribunal);
        uint256 minimumAmount = amount;

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

        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            recipient: claimant,
            expires: expires,
            token: address(0),
            minimumAmount: minimumAmount,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            decayCurve: new uint256[](0),
            salt: bytes32(0)
        });

        vm.chainId(destination);
        bytes32 mandateHash = destinationTribunal.deriveMandateHash(mandate);
        vm.chainId(origin);

        Tribunal.Compact memory compact = Tribunal.Compact({
            arbiter: arbiter,
            sponsor: swapper,
            nonce: nonce,
            expires: expires,
            id: id,
            amount: amount
        });

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

        Tribunal.Claim memory claim = Tribunal.Claim({
            chainId: origin,
            compact: compact,
            sponsorSignature: sponsorSignature,
            allocatorSignature: allocatorSignature
        });

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

    function test_hyperlane_tribunal_claimWithWitnessERC20() public {
        hyperlane_tribunal_setup();

        ResetPeriod resetPeriod = ResetPeriod.TenMinutes;
        Scope scope = Scope.Multichain;
        uint256 amount = 1e18;
        uint256 nonce = 0;
        uint256 expires = block.timestamp + 1000;
        address claimant = 0x1111111111111111111111111111111111111111;
        address arbiter = address(originTribunal);
        uint256 minimumAmount = amount;

        vm.prank(allocator);
        theCompact.__registerAllocator(allocator, "");

        vm.prank(swapper);
        uint256 id = theCompact.deposit(
            address(token),
            allocator,
            resetPeriod,
            scope,
            amount,
            swapper
        );
        assertEq(theCompact.balanceOf(swapper, id), amount);

        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            recipient: claimant,
            expires: expires,
            token: address(token),
            minimumAmount: minimumAmount,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            decayCurve: new uint256[](0),
            salt: bytes32(0)
        });

        vm.chainId(destination);
        bytes32 mandateHash = destinationTribunal.deriveMandateHash(mandate);
        vm.chainId(origin);

        Tribunal.Compact memory compact = Tribunal.Compact({
            arbiter: arbiter,
            sponsor: swapper,
            nonce: nonce,
            expires: expires,
            id: id,
            amount: amount
        });

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

        Tribunal.Claim memory claim = Tribunal.Claim({
            chainId: origin,
            compact: compact,
            sponsorSignature: sponsorSignature,
            allocatorSignature: allocatorSignature
        });

        vm.chainId(destination);
        vm.startPrank(filler);
        destinationTribunal.fill(claim, mandate, filler);
        vm.stopPrank();

        vm.chainId(origin);
        originMailbox.processNextInboundMessage();

        assertEq(theCompact.balanceOf(swapper, id), 0);
        assertEq(theCompact.balanceOf(claimant, id), 0);
        assertEq(token.balanceOf(address(theCompact)), 0);
        assertEq(token.balanceOf(address(claimant)), minimumAmount);
        assertEq(token.balanceOf(address(filler)), amount);
    }

    function test_hyperlane_tribunal_qualifiedClaimWithWitnessETH() public {
        hyperlane_tribunal_setup();

        ResetPeriod resetPeriod = ResetPeriod.TenMinutes;
        Scope scope = Scope.Multichain;
        uint256 amount = 1e18;
        uint256 nonce = 0;
        uint256 expires = block.timestamp + 1000;
        address claimant = 0x1111111111111111111111111111111111111111;
        address arbiter = address(originTribunal);

        uint256 minimumAmount = amount;
        uint256 targetBlock = block.number + 10;
        uint256 maximumBlocksAfterTarget = 5;

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

        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            recipient: claimant,
            expires: expires,
            token: address(0),
            minimumAmount: minimumAmount,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            decayCurve: new uint256[](0),
            salt: bytes32(0)
        });

        vm.chainId(destination);
        bytes32 mandateHash = destinationTribunal.deriveMandateHash(mandate);
        vm.chainId(origin);

        Tribunal.Compact memory compact = Tribunal.Compact({
            arbiter: arbiter,
            sponsor: swapper,
            nonce: nonce,
            expires: expires,
            id: id,
            amount: amount
        });

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

        bytes32 qualificationTypehash = keccak256(
            "TargetBlock(bytes32 claimHash,uint256 targetBlock,uint256 maximumBlocksAfterTarget)"
        );
        bytes32 qualifiedClaimHash = keccak256(
            abi.encode(
                qualificationTypehash,
                claimHash,
                targetBlock,
                maximumBlocksAfterTarget
            )
        );

        bytes32 allocatorDigest = keccak256(
            abi.encodePacked(
                bytes2(0x1901),
                theCompact.DOMAIN_SEPARATOR(),
                qualifiedClaimHash
            )
        );

        (r, vs) = vm.signCompact(allocatorPrivateKey, allocatorDigest);
        bytes memory allocatorSignature = abi.encodePacked(r, vs);

        Tribunal.Claim memory claim = Tribunal.Claim({
            chainId: origin,
            compact: compact,
            sponsorSignature: sponsorSignature,
            allocatorSignature: allocatorSignature
        });

        vm.chainId(destination);
        vm.roll(targetBlock);
        vm.startPrank(filler);
        destinationTribunal.fill{value: amount}(
            claim,
            mandate,
            filler,
            targetBlock,
            maximumBlocksAfterTarget
        );
        vm.stopPrank();

        vm.chainId(origin);
        originMailbox.processNextInboundMessage();

        assertEq(theCompact.balanceOf(swapper, id), 0);
        assertEq(theCompact.balanceOf(claimant, id), 0);
        assertEq(address(theCompact).balance, 0);
        assertEq(address(claimant).balance, minimumAmount);
        assertEq(address(filler).balance, amount);
    }

    function test_hyperlane_tribunal_qualifiedClaimWithWitnessERC20() public {
        hyperlane_tribunal_setup();

        ResetPeriod resetPeriod = ResetPeriod.TenMinutes;
        Scope scope = Scope.Multichain;
        uint256 amount = 1e18;
        uint256 nonce = 0;
        uint256 expires = block.timestamp + 1000;
        address claimant = 0x1111111111111111111111111111111111111111;
        address arbiter = address(originTribunal);

        uint256 minimumAmount = amount;
        uint256 targetBlock = block.number + 10;
        uint256 maximumBlocksAfterTarget = 5;

        vm.prank(allocator);
        theCompact.__registerAllocator(allocator, "");

        vm.prank(swapper);
        uint256 id = theCompact.deposit(
            address(token),
            allocator,
            resetPeriod,
            scope,
            amount,
            swapper
        );
        assertEq(theCompact.balanceOf(swapper, id), amount);

        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            recipient: claimant,
            expires: expires,
            token: address(token),
            minimumAmount: minimumAmount,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            decayCurve: new uint256[](0),
            salt: bytes32(0)
        });

        vm.chainId(destination);
        bytes32 mandateHash = destinationTribunal.deriveMandateHash(mandate);
        vm.chainId(origin);

        Tribunal.Compact memory compact = Tribunal.Compact({
            arbiter: arbiter,
            sponsor: swapper,
            nonce: nonce,
            expires: expires,
            id: id,
            amount: amount
        });

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

        bytes32 qualificationTypehash = keccak256(
            "TargetBlock(bytes32 claimHash,uint256 targetBlock,uint256 maximumBlocksAfterTarget)"
        );
        bytes32 qualifiedClaimHash = keccak256(
            abi.encode(
                qualificationTypehash,
                claimHash,
                targetBlock,
                maximumBlocksAfterTarget
            )
        );

        bytes32 allocatorDigest = keccak256(
            abi.encodePacked(
                bytes2(0x1901),
                theCompact.DOMAIN_SEPARATOR(),
                qualifiedClaimHash
            )
        );

        (r, vs) = vm.signCompact(allocatorPrivateKey, allocatorDigest);
        bytes memory allocatorSignature = abi.encodePacked(r, vs);

        Tribunal.Claim memory claim = Tribunal.Claim({
            chainId: origin,
            compact: compact,
            sponsorSignature: sponsorSignature,
            allocatorSignature: allocatorSignature
        });

        vm.chainId(destination);
        vm.roll(targetBlock);
        vm.startPrank(filler);
        destinationTribunal.fill(
            claim,
            mandate,
            filler,
            targetBlock,
            maximumBlocksAfterTarget
        );
        vm.stopPrank();

        vm.chainId(origin);
        originMailbox.processNextInboundMessage();

        assertEq(theCompact.balanceOf(swapper, id), 0);
        assertEq(theCompact.balanceOf(claimant, id), 0);
        assertEq(token.balanceOf(address(theCompact)), 0);
        assertEq(token.balanceOf(address(claimant)), minimumAmount);
        assertEq(token.balanceOf(address(filler)), amount);
    }

    function test_hyperlane_tribunal_claimWithWitnessSwap() public {
        hyperlane_tribunal_setup();

        ResetPeriod resetPeriod = ResetPeriod.TenMinutes;
        Scope scope = Scope.Multichain;
        uint256 amount = 1e18;
        uint256 nonce = 0;
        uint256 expires = block.timestamp + 1000;
        address claimant = 0x1111111111111111111111111111111111111111;
        address arbiter = address(originTribunal);
        uint256 minimumAmount = amount;

        vm.prank(allocator);
        theCompact.__registerAllocator(allocator, "");

        vm.prank(swapper);
        uint256 id = theCompact.deposit(
            address(token),
            allocator,
            resetPeriod,
            scope,
            amount,
            swapper
        );
        assertEq(theCompact.balanceOf(swapper, id), amount);

        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            recipient: claimant,
            expires: expires,
            token: address(0),
            minimumAmount: minimumAmount,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            decayCurve: new uint256[](0),
            salt: bytes32(0)
        });

        vm.chainId(destination);
        bytes32 mandateHash = destinationTribunal.deriveMandateHash(mandate);
        vm.chainId(origin);

        Tribunal.Compact memory compact = Tribunal.Compact({
            arbiter: arbiter,
            sponsor: swapper,
            nonce: nonce,
            expires: expires,
            id: id,
            amount: amount
        });

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

        Tribunal.Claim memory claim = Tribunal.Claim({
            chainId: origin,
            compact: compact,
            sponsorSignature: sponsorSignature,
            allocatorSignature: allocatorSignature
        });

        vm.chainId(destination);
        vm.startPrank(filler);
        destinationTribunal.fill{value: minimumAmount}(claim, mandate, filler);
        vm.stopPrank();

        vm.chainId(origin);
        originMailbox.processNextInboundMessage();

        assertEq(theCompact.balanceOf(swapper, id), 0);
        assertEq(theCompact.balanceOf(claimant, id), 0);
        assertEq(token.balanceOf(address(theCompact)), 0);
        assertEq(address(claimant).balance, minimumAmount);
        assertEq(token.balanceOf(address(filler)), amount + 1e18);
    }
}
