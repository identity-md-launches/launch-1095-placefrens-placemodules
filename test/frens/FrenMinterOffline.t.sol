// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FrensEthFixture, EthMinterPoolModel} from "../helpers/FrensEthFixture.sol";
import {FrensPlan} from "src/FrensPlan.sol";
import {FrenMinter} from "src/frens/FrenMinter.sol";
import {IMD6900Frens} from "src/frens/IMD6900Frens.sol";
import {FrenWorkerGate} from "src/frens/FrenWorkerGate.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract EthRefundReceiver {
    FrenMinter internal immutable minter;
    bool public reject;
    uint256 public callbacks;
    bool public mintReentered;
    bool public buyReentered;
    bytes public mintError;
    bytes public buyError;

    constructor(FrenMinter minter_) {
        minter = minter_;
    }

    function setReject(bool value) external {
        reject = value;
    }

    receive() external payable {
        require(!reject, "refund refused");
        ++callbacks;
        (mintReentered, mintError) = address(minter).call(abi.encodeCall(minter.mintWithEth, (1, type(uint256).max)));
        (buyReentered, buyError) = address(minter).call(abi.encodeCall(minter.buyImd, (1)));
    }
}

contract FrenMinterOfflineTest is FrensEthFixture {
    function test_EthMintSpendsCallersCreditAndKeepsTheirTier() public {
        _wl(alice, 10);
        imd.mint(alice, 70e18);
        uint256 price = frens.quote(10);
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        (uint256 id, uint256 spent) = minter.mintWithEth{value: 1 ether}(10, price);
        assertEq(spent, (price + 999) / 1000);
        assertEq(balanceBefore - alice.balance, spent);
        (address who, uint8 tier,,, uint8 count,,, uint32 first,,) = frens.requests(id);
        assertEq(who, alice);
        assertEq(tier, 2, "paying ETH must not debit the tier bag");
        assertEq(count, 10);
        assertEq(frens.ownerOf(first), alice);
        assertEq(frens.ownerOf(first + count - 1), alice);
        assertEq(imd.balanceOf(alice), 70e18);
        assertEq(gate.credits(alice), 0);
        assertEq(gate.workerMinted(), 10);
        assertEq(imd.balanceOf(address(frens)), price);
        assertEq(frens.floorImd() + frens.jobBudget(), price);
        _assertSettled();
    }

    function test_MinterCannotBorrowAnotherWalletsGateCredit() public {
        _wl(alice, 1);
        address bob = makeAddr("offline ETH minter bob");
        vm.deal(bob, 1 ether);
        bytes32 beforeState = _snapshot(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(FrenWorkerGate.NoCredit.selector, 0));
        minter.mintWithEth{value: 0.1 ether}(1, type(uint256).max);
        assertEq(_snapshot(bob), beforeState);
        assertEq(gate.credits(alice), 1);
    }

    function test_TierFailureRestoresCreditsSwapAndPayment() public {
        _wl(alice, 2);
        bytes32 beforeState = _snapshot(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMD6900Frens.OverTierLimit.selector, uint8(1)));
        minter.mintWithEth{value: 0.1 ether}(2, type(uint256).max);
        assertEq(_snapshot(alice), beforeState);
    }

    function test_ClosedMintRollsBackAnAlreadySettledSwap() public {
        _openPublic();
        vm.prank(FrensPlan.OWNER);
        frens.setMintOpen(false);
        bytes32 beforeState = _snapshot(alice);
        vm.prank(alice);
        vm.expectRevert(IMD6900Frens.MintClosed.selector);
        minter.mintWithEth{value: 0.1 ether}(1, type(uint256).max);
        assertEq(_snapshot(alice), beforeState);
    }

    function test_QuoteAndMintMaxPayDifferByOneWei() public {
        _openPublic();
        uint256 price = frens.quote(1);
        bytes32 beforeState = _snapshot(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FrenMinter.TooPricey.selector, price));
        minter.mintWithEth{value: 1 ether}(1, price - 1);
        assertEq(_snapshot(alice), beforeState);
        vm.prank(alice);
        minter.mintWithEth{value: 1 ether}(1, price);
        assertEq(frens.balanceOf(alice), 1);
        _assertSettled();
    }

    function test_OneWeiUnderfundingRollsBackAndExactPaymentSucceeds() public {
        _openPublic();
        (uint256 needed,) = minter.quoteEth(1);
        bytes32 beforeState = _snapshot(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FrenMinter.NotEnoughEth.selector, needed));
        minter.mintWithEth{value: needed - 1}(1, type(uint256).max);
        assertEq(_snapshot(alice), beforeState);
        vm.prank(alice);
        (, uint256 spent) = minter.mintWithEth{value: needed}(1, type(uint256).max);
        assertEq(spent, needed);
        _assertSettled();
    }

    function test_PartialExactOutputCannotMintOrBuy() public {
        _openPublic();
        manager.configure(9_999, 0);
        bytes32 beforeState = _snapshot(alice);
        vm.startPrank(alice);
        vm.expectRevert(FrenMinter.Short.selector);
        minter.mintWithEth{value: 1 ether}(1, type(uint256).max);
        vm.expectRevert(FrenMinter.Short.selector);
        minter.buyImd{value: 1 ether}(1e18);
        vm.stopPrank();
        assertEq(_snapshot(alice), beforeState);
    }

    function test_InvalidCountsDoNotLeavePaidSwapsBehind() public {
        _openPublic();
        bytes32 beforeState = _snapshot(alice);
        vm.startPrank(alice);
        vm.expectRevert(IMD6900Frens.SoldOut.selector);
        minter.mintWithEth{value: 1 ether}(0, type(uint256).max);
        vm.expectRevert(IMD6900Frens.BadRequest.selector);
        minter.mintWithEth{value: 1 ether}(70, type(uint256).max);
        vm.expectRevert(IMD6900Frens.BadRequest.selector);
        minter.mintWithEth{value: 1 ether}(type(uint8).max, type(uint256).max);
        vm.stopPrank();
        assertEq(_snapshot(alice), beforeState);
    }

    function test_OnlyPoolManagerCanEnterAnyCallbackMode() public {
        bytes32 beforeState = _snapshot(alice);
        for (uint8 mode; mode < 4; ++mode) {
            vm.prank(alice);
            vm.expectRevert(FrenMinter.OnlyPoolManager.selector);
            minter.unlockCallback(abi.encode(mode, 1e18, 1 ether));
        }
        vm.expectRevert(FrenMinter.OnlyPoolManager.selector);
        minter.unlockCallback("");
        assertEq(_snapshot(alice), beforeState);
    }

    function test_AllQuotesUnwindPoolAccountingAndTokenTransfers() public {
        bytes32 beforeState = _snapshot(alice);
        (uint256 ethIn, uint256 imdOut) = minter.quoteEth(1);
        assertEq(imdOut, frens.quote(1));
        assertEq(ethIn, (imdOut + 999) / 1000);
        (uint256 input, uint256 output) = minter.quoteFloor(3e18);
        assertEq(input, 3e18);
        assertEq(output, 21e18);
        (input, output) = minter.quoteFloorEth(0.01 ether);
        assertEq(input, 0.01 ether);
        assertEq(output, 70e18);
        assertEq(_snapshot(alice), beforeState, "a quote is a reverting simulation");
    }

    function test_QuotesBubblePoolErrorsInsteadOfReturningZero() public {
        bytes memory reason = abi.encodeWithSignature("HookPaused(uint256)", 42);
        manager.setFailure(reason);
        bytes32 beforeState = _snapshot(alice);
        vm.expectRevert(reason);
        minter.quoteEth(1);
        vm.expectRevert(reason);
        minter.quoteFloor(1e18);
        vm.expectRevert(reason);
        minter.quoteFloorEth(1e15);
        vm.prank(alice);
        vm.expectRevert(reason);
        minter.buyImd{value: 1 ether}(1e18);
        assertEq(_snapshot(alice), beforeState);
    }

    function test_ZeroBuyRevertsAndOneWeiBuySettles() public {
        bytes32 beforeState = _snapshot(alice);
        vm.prank(alice);
        vm.expectRevert(EthMinterPoolModel.SwapAmountCannotBeZero.selector);
        minter.buyImd{value: 1}(0);
        assertEq(_snapshot(alice), beforeState);
        vm.prank(alice);
        uint256 spent = minter.buyImd{value: 1}(1);
        assertEq(spent, 1);
        assertEq(imd.balanceOf(alice), 1);
        _assertSettled();
    }

    function test_ExcessOutputGoesBackToThePayer() public {
        _openPublic();
        manager.configure(10_000, 17);
        uint256 price = frens.quote(1);
        vm.prank(alice);
        minter.mintWithEth{value: 1 ether}(1, price);
        assertEq(imd.balanceOf(alice), 17);
        assertEq(imd.balanceOf(address(frens)), price);
        vm.prank(alice);
        minter.buyImd{value: 1 ether}(1e18);
        assertEq(imd.balanceOf(alice), 1e18 + 34);
        _assertSettled();
    }

    function test_RefundRejectionRevertsMintAndBuyAtomically() public {
        _openPublic();
        EthRefundReceiver receiver = new EthRefundReceiver(minter);
        receiver.setReject(true);
        vm.deal(address(receiver), 2 ether);
        bytes32 beforeState = _snapshot(address(receiver));
        vm.startPrank(address(receiver));
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        minter.mintWithEth{value: 1 ether}(1, type(uint256).max);
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        minter.buyImd{value: 1 ether}(1e18);
        vm.stopPrank();
        assertEq(_snapshot(address(receiver)), beforeState);
        assertEq(frens.balanceOf(address(receiver)), 0);
        // Exact payment does not require a payable recipient callback.
        (uint256 exact,) = minter.quoteEth(1);
        vm.prank(address(receiver));
        minter.mintWithEth{value: exact}(1, type(uint256).max);
        assertEq(frens.balanceOf(address(receiver)), 1);
        assertEq(receiver.callbacks(), 0);
    }

    function test_RefundCallbackCannotReenterEitherValueEntryPoint() public {
        _openPublic();
        EthRefundReceiver receiver = new EthRefundReceiver(minter);
        vm.deal(address(receiver), 2 ether);
        vm.prank(address(receiver));
        minter.mintWithEth{value: 1 ether}(1, type(uint256).max);
        assertEq(frens.balanceOf(address(receiver)), 1);
        vm.prank(address(receiver));
        minter.buyImd{value: 1 ether}(1e18);
        assertEq(receiver.callbacks(), 2);
        assertFalse(receiver.mintReentered());
        assertFalse(receiver.buyReentered());
        assertEq(receiver.mintError(), abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector));
        assertEq(receiver.buyError(), abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector));
        assertEq(frens.totalMinted(), 1);
        assertEq(imd.balanceOf(address(receiver)), 1e18);
        _assertSettled();
    }

    function test_LastFrenAndSoldOutDoNotAcceptMoreEth() public {
        _openPublic();
        imd.mint(alice, 1_000_000e18);
        vm.startPrank(alice);
        imd.approve(address(frens), type(uint256).max);
        for (uint256 i; i < 32; ++i) {
            frens.requestMint(69, type(uint256).max);
        }
        frens.requestMint(13, type(uint256).max);
        vm.stopPrank();
        assertEq(frens.totalMinted(), 2221);
        assertEq(minter.maxRequest(alice, true), 1);
        vm.prank(alice);
        minter.mintWithEth{value: 1 ether}(1, type(uint256).max);
        assertEq(frens.totalMinted(), 2222);
        assertEq(minter.maxRequest(alice, true), 0);
        bytes32 beforeState = _snapshot(alice);
        vm.prank(alice);
        vm.expectRevert(IMD6900Frens.SoldOut.selector);
        minter.mintWithEth{value: 1 ether}(1, type(uint256).max);
        assertEq(_snapshot(alice), beforeState);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_BuyImdConservesPaymentAndRefund(uint256 output, uint256 extra) public {
        output = bound(output, 1, 10_000e18);
        extra = bound(extra, 0, 1 ether);
        uint256 expectedSpent = (output + 999) / 1000;
        uint256 beforeBalance = alice.balance;
        uint256 poolBefore = imd.balanceOf(address(manager));
        vm.prank(alice);
        uint256 spent = minter.buyImd{value: expectedSpent + extra}(output);
        assertEq(spent, expectedSpent);
        assertEq(beforeBalance - alice.balance, spent);
        assertEq(address(manager).balance, spent);
        assertEq(imd.balanceOf(alice), output);
        assertEq(poolBefore - imd.balanceOf(address(manager)), output);
        _assertSettled();
    }

    function _assertSettled() internal view {
        assertFalse(manager.unlocked());
        assertEq(manager.locker(), address(0));
        assertEq(manager.ethDelta(), 0);
        assertEq(manager.imdDelta(), 0);
        assertEq(manager.floorDelta(), 0);
        assertEq(address(minter).balance, 0);
        assertEq(imd.balanceOf(address(minter)), 0);
        assertEq(imd.allowance(address(minter), address(frens)), 0);
    }
}
