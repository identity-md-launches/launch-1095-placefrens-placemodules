// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FrensResidualRisksTest, ResidualRiskPool} from "./FrensResidualRisks.t.sol";
import {IMD6900Frens} from "../src/frens/IMD6900Frens.sol";
import {FrenWorkerGate} from "../src/frens/FrenWorkerGate.sol";
import {FrenMinter} from "../src/frens/FrenMinter.sol";
import {FrenSwapper} from "../src/frens/FrenSwapper.sol";
import {FrensPlan} from "../src/FrensPlan.sol";
import {MockToken} from "./frens/IMD6900Frens.t.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IRevisionCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @dev Offline constant-product POOL4, 1% input fee, no hook burn or concentrated liquidity.
///      Models settlement for the real minter, slot0 for the real swapper, and a completed unlock.
contract RevisionPool {
    uint256 public x;
    uint256 public y;
    bytes32 public ethSlot;
    bool internal unlocked;

    function init(bytes32 slot) external {
        x = 23.37 ether;
        y = 7400e18;
        ethSlot = slot;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        uint256 p = slot == ethSlot ? Math.sqrt(y * 1e36 / x) * (1 << 96) / 1e18 : uint256(1 << 96) / 265;
        return bytes32(p);
    }

    function exttload(bytes32) external view returns (bytes32) {
        return bytes32(uint256(unlocked ? 1 : 0));
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(!unlocked);
        unlocked = true;
        result = IRevisionCallback(msg.sender).unlockCallback(data);
        unlocked = false;
    }

    function swap(PoolKey calldata key, SwapParams calldata p, bytes calldata) external returns (BalanceDelta) {
        require(unlocked);
        bool eth = Currency.unwrap(key.currency0) == address(0);
        if (!eth) {
            // Quote paths use an unlimited pair leg, regardless of the floor buy's bound.
            require(p.sqrtPriceLimitX96 == (p.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1));
            uint256 a = uint256(-p.amountSpecified);
            return p.zeroForOne
                ? toBalanceDelta(-int128(int256(a)), int128(int256(a * 70_000)))
                : toBalanceDelta(int128(int256(a * 70_000)), -int128(int256(a)));
        }
        require(p.zeroForOne && p.sqrtPriceLimitX96 == TickMath.MIN_SQRT_PRICE + 1);
        uint256 spent;
        uint256 got;
        if (p.amountSpecified > 0) {
            got = uint256(p.amountSpecified);
            // Round the exact-output payment up, so this model never undercharges fees.
            spent = Math.ceilDiv(x * got * 100, (y - got) * 99);
            x += spent;
            y -= got;
        } else {
            spent = uint256(-p.amountSpecified);
            got = push(spent);
        }
        return toBalanceDelta(-int128(int256(spent)), int128(int256(got)));
    }

    function settle() external payable returns (uint256) {
        return msg.value;
    }

    function take(Currency token, address to, uint256 amount) external {
        require(unlocked);
        MockToken(Currency.unwrap(token)).mint(to, amount);
    }

    /// @dev Reserve arithmetic for an external completed push/unpush; tokens are not custodied here.
    function push(uint256 eth) public returns (uint256 imd) {
        uint256 effective = eth * 99 / 100;
        imd = y * effective / (x + effective);
        x += eth;
        y -= imd;
    }

    function unpush(uint256 imd) external returns (uint256 eth) {
        uint256 effective = imd * 99 / 100;
        eth = x * effective / (y + effective);
        y += imd;
        x -= eth;
    }
}

contract RevisionFee {
    uint256 public fee = 690;

    function set(uint256 f) external {
        fee = f;
    }
}

contract RevisionLimitProbe is FrenSwapper {
    constructor(address pool, address fee)
        FrenSwapper(pool, FrensPlan.IMD, FrensPlan.IMD6900, FrensPlan.FRENS_AT, fee, FrensPlan.POOL4_HOOK)
    {}

    function limit(PoolKey memory key, bool direction, uint256 move) external view returns (uint160) {
        return _limit(key, direction, move);
    }
}

/// @notice Passing tests document retained MEDIUM/LOW/INFO behavior, not repaired contracts.
contract FrensRevisionRisksTest is FrensResidualRisksTest {
    function _paused() internal {
        vm.prank(FrensPlan.OWNER);
        frens.setParams(1, 0, 0);
    }

    function test_Risk_RecycleOmitsPendingEthPricedByTreasury() public {
        _mint(alice, 1);
        vm.roll(vm.getBlockNumber() + 1);
        _mint(bob, 1);
        vm.deal(address(frens), 1 ether);
        assertGt(frens.quote(1), 1500e18);
        vm.prank(alice);
        (uint256 tokenPart, uint256 imdPart) = frens.recycle(1);
        assertEq(imdPart, 0);
        assertEq(tokenPart / 70_000, 0.19025e18);
        assertEq(address(frens).balance, 1 ether);
        vm.prank(bob);
        vm.expectRevert(IMD6900Frens.Cap.selector);
        frens.buyTreasury(1, type(uint256).max, 1);
        reserveToken.mint(bob, 1_000_000e18);
        vm.prank(bob);
        reserveToken.approve(address(frens), type(uint256).max);
        vm.prank(bob);
        (, uint256 treasuryImd) = frens.buyTreasury(1, type(uint256).max, type(uint256).max);
        assertEq(treasuryImd, 6000e18);
    }

    function test_Risk_FloorViewOmitsJobRefund() public {
        _mint(alice, 3);
        vm.prank(alice);
        frens.recycle(1);
        _paused();
        imd.mint(address(frens), 0.25e18);
        (uint256 tokenPart, uint256 imdPart) = frens.floorPerFren();
        assertEq(imdPart, 0);
        vm.prank(bob);
        vm.expectRevert(IMD6900Frens.Cap.selector);
        frens.buyTreasury(1, 2 * tokenPart, 2 * imdPart);
        vm.prank(alice);
        (, uint256 got) = frens.recycle(2);
        assertEq(got, 0.125e18);
    }

    function test_Risk_DustEthTakesFiftyBlockTurns() public {
        _mint(alice, 2);
        vm.deal(address(frens), 10 ether);
        uint256 before = frens.reserve();
        for (uint256 i; i < 50; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.prank(bob);
            frens.buyFloorWithEth(1, 0);
            vm.expectRevert(IMD6900Frens.TooSoon.selector);
            frens.buyFloorWithEth(0.25 ether, 0);
        }
        assertEq(address(frens).balance, 10 ether - 50);
        assertEq(frens.reserve() - before, 50 * 70_000 * 3000);
    }

    function test_Risk_PayeeChangeLeavesExpiredPermitDigest() public {
        uint256 id = _mint(alice, 1);
        uint256 deadline = vm.getBlockTimestamp() + 600;
        IMD6900Frens.Quote memory q =
            IMD6900Frens.Quote("r", bytes32("s"), "q", bytes32("qh"), bytes32("ph"), "job.open", deadline);
        vm.prank(FrensPlan.KEEPER);
        (bytes32 oldDigest,) = frens.approveJob(id, 1, deadline, q);
        vm.prank(FrensPlan.OWNER);
        frens.setRoles(address(0), address(0), makeAddr("changed payee"));
        vm.warp(deadline + 1);
        q.expiresAt = vm.getBlockTimestamp() + 600;
        vm.prank(FrensPlan.KEEPER);
        frens.approveJob(id, 2, q.expiresAt, q);
        assertEq(imd.allowance(address(frens), address(permit2)), 0.5e18);
        assertEq(frens.isValidSignature(oldDigest, ""), bytes4(0x1626ba7e));
    }

    function test_Risk_StrangerSpendsWorkersCredit() public {
        FrenWorkerGate gate = new FrenWorkerGate(FrensPlan.OWNER, address(frens), FrensPlan.IDENTITY, FrensPlan.IMD6900);
        vm.startPrank(FrensPlan.OWNER);
        frens.setModules(address(fixedSwapper), address(gate));
        gate.setWlRoot(keccak256(bytes.concat(keccak256(abi.encode(alice, uint256(1))))));
        vm.stopPrank();
        vm.prank(alice);
        gate.claimWl(1, new bytes32[](0), alice);
        assertEq(gate.credits(alice), 1);
        vm.prank(bob);
        frens.requestMintFor(alice, 1, type(uint256).max);
        assertEq(gate.credits(alice), 0);
        assertEq(gate.workerMinted(), 1);
        assertEq(frens.ownerOf(1), alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FrenWorkerGate.NoCredit.selector, 0));
        frens.requestMint(1, type(uint256).max);
    }

    function test_Risk_FloorBoundJobCostIsSocialised() public {
        _mint(alice, 69);
        _mint(alice, 31);
        vm.deal(address(frens), 0.25 ether);
        vm.roll(vm.getBlockNumber() + 1);
        frens.buyFloorWithEth(0.25 ether, 0);
        uint256 valueBefore = frens.reserve() / 70_000 + frens.floorImd();
        uint256 cost = frens.quote(1);
        assertGt(cost, frens.priceOf(100));
        _mint(bob, 1);
        vm.prank(bob);
        (uint256 tokenPart, uint256 imdPart) = frens.recycle(101);
        uint256 loss = cost - (tokenPart / 70_000 + imdPart);
        assertApproxEqAbs(loss, uint256(0.5e18) / 101, 2);
        uint256 valueAfter = frens.reserve() / 70_000 + frens.floorImd();
        assertApproxEqAbs(valueBefore - valueAfter, 0.5e18 - loss, 2);
    }

    function _pool() internal returns (RevisionPool pool, FrenSwapper swapper, FrenMinter minter) {
        vm.etch(FrensPlan.POOL_MANAGER, address(new RevisionPool()).code);
        pool = RevisionPool(FrensPlan.POOL_MANAGER);
        pool.init(
            _slot(keccak256(abi.encode(address(0), FrensPlan.IMD, uint24(10_000), int24(60), FrensPlan.POOL4_HOOK)))
        );
        swapper = new FrenSwapper(
            FrensPlan.POOL_MANAGER,
            FrensPlan.IMD,
            FrensPlan.IMD6900,
            address(frens),
            FrensPlan.PAIR_HOOK,
            FrensPlan.POOL4_HOOK
        );
        minter = new FrenMinter(FrensPlan.POOL_MANAGER, address(frens), FrensPlan.POOL4_HOOK, FrensPlan.PAIR_HOOK);
        vm.prank(FrensPlan.OWNER);
        frens.setModules(address(swapper), address(0));
        _paused();
    }

    function test_Risk_EthMintPushesItsOwnPendingEthPrice() public {
        (RevisionPool pool, FrenSwapper swapper, FrenMinter minter) = _pool();
        _mint(alice, 2);
        vm.deal(address(frens), 1 ether);
        uint256 oldShare = frens.quote(1);
        uint256 shown = frens.quote(10);
        uint256 oldSpot = swapper.imdPerEth();
        uint256 before = imd.balanceOf(bob);
        uint256 bookedBefore = frens.floorImd();
        vm.deal(bob, 20 ether);
        vm.prank(bob);
        (, uint256 ethSpent) = minter.mintWithEth{value: 20 ether}(10, shown);
        uint256 refund = imd.balanceOf(bob) - before;
        uint256 paid = frens.floorImd() - bookedBefore + frens.JOB_PRICE();
        assertGt(refund, 600e18);
        assertEq(paid + refund, shown);
        assertApproxEqAbs(ethSpent, 6.4479 ether, 0.001 ether);
        assertLt(swapper.imdPerEth(), oldSpot);
        assertEq(address(frens).balance, 1 ether);
        // Return the model to its original reserves, representing post-mint arbitrage.
        pool.init(pool.ethSlot());
        assertLt(frens.quote(1), oldShare * 7 / 10);
        emit log_named_uint("shown IMD", shown);
        emit log_named_uint("paid IMD", paid);
        emit log_named_uint("refunded IMD", refund);
    }

    function test_Risk_PushMintUnpushHasPositiveMarkedValue() public {
        (RevisionPool pool, FrenSwapper swapper,) = _pool();
        _mint(alice, 2);
        vm.deal(address(frens), 1 ether);
        uint256 honest = frens.quote(69);
        uint256 oldShare = frens.quote(1);
        uint256 bought = pool.push(9.5 ether);
        uint256 paid = frens.quote(69);
        _mint(bob, 69);
        uint256 recoveredEth = pool.unpush(bought);
        uint256 finalSpot = swapper.imdPerEth();
        uint256 markedFrens = 69 * frens.quote(1);
        uint256 roundTripImd = (9.5 ether - recoveredEth) * finalSpot / 1e18;
        assertLt(paid, honest * 6 / 10);
        assertGt(markedFrens, paid + roundTripImd);
        assertLt(frens.quote(1), oldShare * 6 / 10);
        emit log_named_uint("round trip ETH cost", 9.5 ether - recoveredEth);
        emit log_named_uint("marked IMD surplus", markedFrens - paid - roundTripImd);
        // Marked pending value is not an immediate recycle payout; hook burns and live liquidity are not modeled.
    }

    function test_Risk_FloorQuotesUseExtremeLimits() public {
        (,, FrenMinter minter) = _pool();
        RevisionFee fee = new RevisionFee();
        RevisionLimitProbe probe = new RevisionLimitProbe(FrensPlan.POOL_MANAGER, address(fee));
        PoolKey memory key = probe.pairKey();
        bool dir = Currency.unwrap(key.currency0) == FrensPlan.IMD;
        uint160 bounded = probe.limit(key, dir, probe.pairMoveBips());
        assertTrue(bounded != (dir ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1));
        assertGt(probe.limit(probe.imdKey(), true, probe.POOL4_MOVE_BIPS()), TickMath.MIN_SQRT_PRICE + 1);
        // The model rejects any non-extreme quote limit on either leg. Quote reverts roll swaps back.
        (uint256 spent, uint256 out) = minter.quoteFloor(50e18);
        assertEq(spent, 50e18);
        assertEq(out, 50e18 * 70_000);
        (spent, out) = minter.quoteFloorEth(0.25 ether);
        assertEq(spent, 0.25 ether);
        assertGt(out, 0);
        assertEq(frens.maxImdPerBuy(), 0);
        assertEq(frens.maxEthPerBuy(), 0);
    }

    function test_Risk_ZeroOrOneFeeLimitEqualsCurrentPrice() public {
        _pool();
        RevisionFee fee = new RevisionFee();
        RevisionLimitProbe probe = new RevisionLimitProbe(FrensPlan.POOL_MANAGER, address(fee));
        uint160 price = uint160(Q96 / 265);
        for (uint256 i; i < 2; ++i) {
            fee.set(i);
            assertEq(probe.pairMoveBips(), 0);
            assertEq(probe.limit(probe.pairKey(), true, probe.pairMoveBips()), price);
            assertEq(probe.limit(probe.pairKey(), false, probe.pairMoveBips()), price);
        }
    }
}
