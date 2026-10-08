// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FrensEthFixture, EthMinterPoolModel, EthFixtureToken} from "../helpers/FrensEthFixture.sol";
import {FrensPlan} from "src/FrensPlan.sol";
import {IMD6900Frens} from "src/frens/IMD6900Frens.sol";
import {FrenMinter} from "src/frens/FrenMinter.sol";
import {FrenWorkerGate} from "src/frens/FrenWorkerGate.sol";

/// @dev Ghosts record operation inputs and externally paid amounts, independently of the collection's books.
/// All target calls either succeed or match a specific expected error. fail_on_revert is enabled below.
contract EthMinterHandler is Test {
    IMD6900Frens public immutable frens;
    FrenMinter public immutable minter;
    FrenWorkerGate public immutable gate;
    EthMinterPoolModel public immutable manager;
    EthFixtureToken public immutable imd;
    address[4] public actors;
    uint256[4] public initialImd;
    uint256[4] public bought;
    uint256[4] public ethSpent;
    uint256[4] public minted;
    uint256[4] public granted;
    uint256[4] public spentCredits;
    uint256 public mintPayments;
    uint256 public requests;
    uint256 public successfulBuys;
    uint256 public rejectedCalls;
    uint256 public quoteCalls;
    bool public opened;

    constructor(IMD6900Frens frens_, FrenMinter minter_, FrenWorkerGate gate_, EthMinterPoolModel manager_) {
        frens = frens_;
        minter = minter_;
        gate = gate_;
        manager = manager_;
        imd = EthFixtureToken(frens_.imd());
        initialImd = [uint256(0), 7e18, 70e18, 700e18];
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("ETH invariant actor ", vm.toString(i)));
            vm.deal(actors[i], 1000 ether);
            imd.mint(actors[i], initialImd[i]);
            _claim(i, 100);
        }
    }

    function mint(uint256 actorSeed, uint256 countSeed, uint256 refundSeed) public {
        uint256 i = actorSeed % 4;
        address actor = actors[i];
        uint256 left = 2222 - frens.totalMinted();
        uint8 tier = frens.tierOf(actor);
        uint256 cap = frens.maxMint(tier);
        if (cap > left) cap = left;
        if (tier < 2) {
            uint256 pepeLeft = 1598 - frens.openLowTier();
            if (cap > pepeLeft) cap = pepeLeft;
        }
        bool window = gate.workerWindow();
        if (window) {
            uint256 credit = gate.credits(actor);
            if (cap > credit) cap = credit;
            uint256 windowLeft = 420 - gate.workerMinted();
            if (cap > windowLeft) cap = windowLeft;
        }
        if (cap == 0) return;
        uint8 count = uint8(bound(countSeed, 1, cap));
        uint256 price = frens.quote(count);
        uint256 ethIn = (price + 999) / 1000;
        uint256 refund = bound(refundSeed, 0, 1 ether);
        manager.configure(10_000, 0);
        uint256 beforeEth = actor.balance;
        uint256 beforeImd = imd.balanceOf(actor);
        vm.prank(actor);
        (uint256 id, uint256 spent) = minter.mintWithEth{value: ethIn + refund}(count, price);
        assertEq(spent, ethIn);
        assertEq(beforeEth - actor.balance, ethIn, "refund belongs to the payer");
        assertEq(imd.balanceOf(actor), beforeImd, "mint must preserve the payer's tier bag");
        (address who, uint8 savedTier,,, uint8 savedCount,,, uint32 first,,) = frens.requests(id);
        assertEq(who, actor);
        assertEq(savedTier, tier);
        assertEq(savedCount, count);
        assertEq(frens.ownerOf(first), actor);
        assertEq(frens.ownerOf(first + count - 1), actor);
        ethSpent[i] += ethIn;
        minted[i] += count;
        mintPayments += price;
        ++requests;
        if (window) spentCredits[i] += count;
    }

    function buy(uint256 actorSeed, uint256 amountSeed, uint256 refundSeed) public {
        uint256 i = actorSeed % 4;
        uint256 amount = bound(amountSeed, 1, 500e18);
        uint256 extra = refundSeed % 1001; // exercise hook excess-output handling as well
        uint256 ethIn = (amount + extra + 999) / 1000;
        uint256 refund = bound(refundSeed, 0, 1 ether);
        manager.configure(10_000, extra);
        uint256 beforeEth = actors[i].balance;
        uint256 beforeImd = imd.balanceOf(actors[i]);
        vm.prank(actors[i]);
        uint256 spent = minter.buyImd{value: ethIn + refund}(amount);
        assertEq(spent, ethIn);
        assertEq(beforeEth - actors[i].balance, ethIn);
        assertEq(imd.balanceOf(actors[i]) - beforeImd, amount + extra);
        ethSpent[i] += ethIn;
        bought[i] += amount + extra;
        ++successfulBuys;
    }

    function rejectMint(uint256 actorSeed, uint256 modeSeed) public {
        if (frens.totalMinted() == 2222) return;
        address actor = actors[actorSeed % 4];
        uint256 price = frens.quote(1);
        uint256 ethIn = (price + 999) / 1000;
        uint256 mode = modeSeed % 3;
        manager.configure(mode == 2 ? 9_999 : 10_000, 0);
        bytes32 beforeState = _snapshot(actor);
        bytes memory reason = mode == 0
            ? abi.encodeWithSelector(FrenMinter.TooPricey.selector, price)
            : mode == 1
                ? abi.encodeWithSelector(FrenMinter.NotEnoughEth.selector, ethIn)
                : abi.encodeWithSelector(FrenMinter.Short.selector);
        vm.prank(actor);
        vm.expectRevert(reason);
        minter.mintWithEth{value: mode == 1 ? ethIn - 1 : ethIn}(1, mode == 0 ? price - 1 : price);
        assertEq(_snapshot(actor), beforeState, "rejected mint must be atomic");
        ++rejectedCalls;
    }

    function quote(uint256 amountSeed) public {
        uint256 amount = bound(amountSeed, 1, 100e18);
        manager.configure(10_000, 0);
        bytes32 beforeState = _snapshot(actors[0]);
        (uint256 input, uint256 output) = minter.quoteFloor(amount);
        assertEq(input, amount);
        assertEq(output, amount * 7);
        (input, output) = minter.quoteFloorEth(amount / 1000 + 1);
        assertEq(input, amount / 1000 + 1);
        assertEq(output, input * 7000);
        if (frens.totalMinted() < 2222) {
            (input, output) = minter.quoteEth(1);
            assertEq(output, frens.quote(1));
            assertEq(input, (output + 999) / 1000);
        }
        assertEq(_snapshot(actors[0]), beforeState, "quote must unwind all pool changes");
        ++quoteCalls;
    }

    function claimMore(uint256 actorSeed, uint256 extraSeed) public {
        uint256 i = actorSeed % 4;
        _claim(i, granted[i] + bound(extraSeed, 1, 420));
    }

    function openPublic(uint256 seed) public {
        if (seed % 8 != 0) return;
        vm.prank(FrensPlan.OWNER);
        gate.openPublic();
        opened = true;
    }

    function _claim(uint256 i, uint256 total) internal {
        vm.prank(FrensPlan.OWNER);
        gate.setWlRoot(keccak256(bytes.concat(keccak256(abi.encode(actors[i], total)))));
        vm.prank(actors[i]);
        gate.claimWl(total, new bytes32[](0), actors[i]);
        granted[i] = total;
    }

    function _snapshot(address actor) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                actor.balance,
                address(manager).balance,
                address(minter).balance,
                imd.balanceOf(actor),
                imd.balanceOf(address(manager)),
                imd.balanceOf(address(minter)),
                imd.balanceOf(address(frens)),
                imd.allowance(address(minter), address(frens)),
                frens.totalMinted(),
                frens.nextRequestId(),
                frens.jobBudget(),
                frens.floorImd(),
                frens.openLowTier(),
                gate.credits(actor),
                gate.workerMinted(),
                manager.unlocks(),
                manager.swaps(),
                manager.unlocked(),
                manager.locker(),
                manager.ethDelta(),
                manager.imdDelta(),
                manager.floorDelta()
            )
        );
    }
}

contract FrenMinterInvariantsTest is FrensEthFixture {
    EthMinterHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new EthMinterHandler(frens, minter, gate, manager);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.buy.selector;
        selectors[2] = handler.rejectMint.selector;
        selectors[3] = handler.quote.selector;
        selectors[4] = handler.claimMore.selector;
        selectors[5] = handler.openPublic.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    /// @dev FrenMinter promises to hold nothing between calls. Every actor's expense must be pool income;
    /// every IMD unit taken must be in a buyer's wallet or the collection, with no remaining allowance/debt.
    function invariant_AllPaymentsRemainAccountedFor() public view {
        uint256 totalEth;
        uint256 bought;
        for (uint256 i; i < 4; ++i) {
            uint256 spent = handler.ethSpent(i);
            totalEth += spent;
            bought += handler.bought(i);
            assertEq(handler.actors(i).balance + spent, 1000 ether);
            assertEq(imd.balanceOf(handler.actors(i)), handler.initialImd(i) + handler.bought(i));
        }
        assertEq(address(manager).balance, totalEth);
        assertEq(imd.balanceOf(address(manager)) + bought + handler.mintPayments(), 1e36);
        assertEq(imd.balanceOf(address(frens)), handler.mintPayments());
        assertEq(frens.floorImd() + frens.jobBudget(), handler.mintPayments());
        assertEq(frens.jobBudget(), handler.requests() * 0.5e18);
        assertEq(address(minter).balance, 0);
        assertEq(imd.balanceOf(address(minter)), 0);
        assertEq(imd.allowance(address(minter), address(frens)), 0);
        assertFalse(manager.unlocked());
        assertEq(manager.locker(), address(0));
        assertEq(manager.ethDelta(), 0);
        assertEq(manager.imdDelta(), 0);
        assertEq(manager.floorDelta(), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    /// @dev An ETH mint must use its caller's credits exactly once. Rejected payments and quotes mint nothing.
    function invariant_RequestsAndWorkerCreditsAreConserved() public view {
        uint256 minted;
        uint256 creditsSpent;
        for (uint256 i; i < 4; ++i) {
            minted += handler.minted(i);
            creditsSpent += handler.spentCredits(i);
            assertEq(frens.balanceOf(handler.actors(i)), handler.minted(i));
            assertEq(gate.credits(handler.actors(i)) + handler.spentCredits(i), handler.granted(i));
        }
        assertEq(frens.totalMinted(), minted);
        assertLe(minted, 2222);
        assertEq(frens.nextRequestId(), handler.requests() + 1);
        assertEq(gate.workerMinted(), creditsSpent);
        assertLe(creditsSpent, 420);
        if (handler.opened() || creditsSpent == 420) assertFalse(gate.workerWindow());
        assertEq(frens.owner(), FrensPlan.OWNER);
        assertEq(frens.governor(), FrensPlan.OWNER);
        assertEq(gate.owner(), FrensPlan.OWNER);
    }

    /// @dev Deterministically exercise every handler path, so a vacuous fuzz campaign cannot hide a broken setup.
    function test_HandlerSequenceExercisesValueAndFailurePaths() public {
        handler.mint(0, 1, 0);
        handler.buy(1, 1e18, 100);
        handler.claimMore(2, 200);
        handler.mint(2, 22, 1 ether);
        handler.rejectMint(0, 0);
        handler.rejectMint(1, 1);
        handler.rejectMint(2, 2);
        handler.quote(10e18);
        handler.openPublic(0);
        handler.mint(3, 69, 0);
        assertEq(handler.requests(), 3);
        assertEq(handler.successfulBuys(), 1);
        assertEq(handler.rejectedCalls(), 3);
        assertEq(handler.quoteCalls(), 1);
        invariant_AllPaymentsRemainAccountedFor();
        invariant_RequestsAndWorkerCreditsAreConserved();
    }
}
