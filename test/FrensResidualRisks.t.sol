// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FrensReviewBase, FrensAllowanceToken} from "./FrensLaunchReview.t.sol";
import {MockToken, NoZeroToken, MockPermit2, MockSwapper} from "./frens/IMD6900Frens.t.sol";
import {FrensRules} from "./frens/FrensRules.sol";
import {PlaceFrens, PlaceModules} from "../src/FrensPlacement.sol";
import {FrensPlan} from "../src/FrensPlan.sol";
import {IMD6900Frens} from "../src/frens/IMD6900Frens.sol";
import {FrenSwapper} from "../src/frens/FrenSwapper.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Only slot0 and the locked flag are modeled; swaps fail, leaving the floor's IMD waiting.
contract ResidualRiskPool {
    mapping(bytes32 => bytes32) internal slots;

    function set(bytes32 slot, uint160 price) external {
        slots[slot] = bytes32(uint256(price));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return slots[slot];
    }

    function exttload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }
}

/// @notice Passing Risk tests confirm unresolved imported findings, NOT repairs. The requester retains MEDIUM/LOW
///         runtime behavior to preserve the timelock's addresses. See ADAPTATION.md for disposition and limitations.
///         Collection and swapper deployments use the actual pinned creation code and production arguments.
contract FrensResidualRisksTest is FrensReviewBase, FrensRules {
    IMD6900Frens internal frens;
    PlaceFrens internal pf;
    MockToken internal imd;
    MockToken internal reserveToken;
    MockPermit2 internal permit2;
    MockSwapper internal fixedSwapper;
    address internal alice;
    address internal bob;
    uint256 internal constant RELAYER_KEY = 0xA11CE;
    uint256 internal constant Q96 = 1 << 96;

    function setUp() public {
        vm.chainId(1);
        vm.etch(FrensPlan.CREATE2_DEPLOYER, DEPLOYER_CODE);
        vm.etch(FrensPlan.IMD, address(new FrensAllowanceToken()).code);
        vm.etch(FrensPlan.IMD6900, address(new NoZeroToken()).code);
        vm.etch(FrensPlan.IDENTITY, address(new MockToken("identity")).code);
        vm.etch(FrensPlan.PERMIT2, address(new MockPermit2()).code);
        imd = MockToken(FrensPlan.IMD);
        reserveToken = MockToken(FrensPlan.IMD6900);
        permit2 = MockPermit2(FrensPlan.PERMIT2);
        pf = PlaceFrens(deployCode("FrensPlacement.sol:PlaceFrens"));
        frens = IMD6900Frens(payable(pf.frens()));
        assertEq(address(frens), FrensPlan.FRENS_AT);
        fixedSwapper = new MockSwapper(reserveToken, imd);
        vm.startPrank(FrensPlan.OWNER);
        _rules(frens, [uint16(1598), 312, 312]);
        frens.sealTraits();
        frens.setModules(address(fixedSwapper), address(0));
        frens.setRoles(address(0), vm.addr(RELAYER_KEY), address(0));
        frens.setMintOpen(true);
        vm.stopPrank();
        alice = makeAddr("residual alice");
        bob = makeAddr("residual bob");
        for (uint256 i; i < 2; ++i) {
            address user = [alice, bob][i];
            imd.mint(user, 10_000e18);
            vm.prank(user);
            imd.approve(address(frens), type(uint256).max);
        }
    }

    function _mint(address user, uint8 count) internal returns (uint256) {
        vm.prank(user);
        return frens.requestMint(count, type(uint256).max);
    }

    function _slot(bytes32 poolId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
    }

    /// @dev a99c13dac6ce: manipulating POOL4 after a completed unlock bypasses the collection's Flash check.
    ///      Slot changes establish the pricing defect; this does not simulate manipulation costs or profitable MEV.
    function test_Risk_PendingEthSpotPushDilutesExistingHolders() public {
        vm.etch(FrensPlan.POOL_MANAGER, address(new ResidualRiskPool()).code);
        ResidualRiskPool pool = ResidualRiskPool(FrensPlan.POOL_MANAGER);
        bytes32 pairSlot =
            _slot(keccak256(abi.encode(FrensPlan.IMD6900, FrensPlan.IMD, uint24(0), int24(60), FrensPlan.PAIR_HOOK)));
        bytes32 ethSlot =
            _slot(keccak256(abi.encode(address(0), FrensPlan.IMD, uint24(10_000), int24(60), FrensPlan.POOL4_HOOK)));
        pool.set(pairSlot, uint160(Q96 / 265));
        pool.set(ethSlot, uint160(Q96 * 15));
        PlaceModules pm = PlaceModules(deployCode("FrensPlacement.sol:PlaceModules", abi.encode(pf)));
        FrenSwapper swapper = FrenSwapper(payable(pm.swapper()));
        assertEq(address(swapper), FrensPlan.SWAPPER_AT);
        vm.prank(FrensPlan.OWNER);
        frens.setModules(address(swapper), address(0));
        _mint(alice, 2);
        assertEq(frens.floorImd(), 0.8805e18);
        vm.deal(address(frens), 1 ether);
        assertEq(swapper.pendingImd(address(frens)), 225e18);
        uint256 honest = frens.quote(1);
        assertEq(honest, 112.94025e18);
        pool.set(ethSlot, uint160(Q96 * 3 / 2));
        assertEq(swapper.pendingImd(address(frens)), 2.25e18);
        uint256 before = imd.balanceOf(bob);
        _mint(bob, 1);
        uint256 paid = before - imd.balanceOf(bob);
        assertEq(paid, 1.56525e18);
        assertLt(paid, honest, "retained risk: the pushed spot underprices the mint");
        pool.set(ethSlot, uint160(Q96 * 15));
        uint256 restoredShare = frens.quote(1);
        assertGt(restoredShare, paid);
        assertLt(restoredShare, honest, "the original holders' shares were diluted");
    }

    /// @dev 2577a172e288: the already-spent nonce fix does not reserve nonces across pending requests.
    function test_Risk_DuplicatePendingNonceStrandsOnePayment() public {
        uint256 a = _mint(alice, 1);
        uint256 b = _mint(alice, 1);
        uint256 deadline = vm.getBlockTimestamp() + 600;
        IMD6900Frens.Quote memory q =
            IMD6900Frens.Quote("r", bytes32("s"), "q", bytes32("qh"), bytes32("ph"), "job.open", deadline);
        vm.startPrank(FrensPlan.KEEPER);
        (bytes32 da,) = frens.approveJob(a, 5, deadline, q);
        (bytes32 db,) = frens.approveJob(b, 5, deadline, q);
        vm.stopPrank();
        assertEq(da, db);
        assertEq(imd.allowance(address(frens), address(permit2)), 1e18);
        vm.prank(address(permit2));
        imd.transferFrom(address(frens), FrensPlan.IMD_PAY_TO, 0.5e18);
        permit2.spend(address(frens), 5);
        vm.warp(deadline + 1);
        _reveal(a, uint24(1 << 2));
        _reveal(b, uint24(2 << 2));
        assertEq(frens.jobBudget(), 0);
        vm.expectRevert(IMD6900Frens.BadJob.selector);
        frens.releaseLapsedJob(b);
        assertEq(imd.allowance(address(frens), address(permit2)), 0.5e18, "retained risk: stranded approval");
        assertEq(frens.isValidSignature(da, ""), bytes4(0x1626ba7e));
        assertEq(imd.balanceOf(address(frens)), frens.floorImd() + 0.5e18);
    }

    function _reveal(uint256 id, uint24 combo) internal {
        uint24[] memory combos = new uint24[](1);
        combos[0] = combo;
        uint256 deadline = vm.getBlockTimestamp() + 600;
        bytes32 hash = frens.voucherDigest(id, combos, "job", bytes32("out"), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(RELAYER_KEY, hash);
        frens.reveal(id, combos, "job", bytes32("out"), deadline, abi.encodePacked(r, s, v), 1);
    }

    /// @dev 7e2a0f99e1d6: requires the governor to remove the swapper while minting remains open.
    function test_Risk_UnwiringSwapperAllowsCheapReserveCapture() public {
        _mint(alice, 2);
        vm.deal(address(frens), 0.1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        frens.buyFloorWithEth(0.1 ether, 0);
        assertEq(frens.reserve() / 70_000, 300.8805e18);
        assertGe(frens.quote(1), 150e18);
        vm.prank(FrensPlan.OWNER);
        frens.setModules(address(0), address(0));
        uint256 paid = frens.quote(1);
        assertEq(paid, frens.priceOf(2));
        assertEq(paid, 0.6908e18);
        _mint(bob, 1);
        vm.prank(bob);
        (uint256 got,) = frens.recycle(3);
        assertEq(got / 70_000, 100.2935e18);
        assertGt(got / 70_000, paid, "retained risk: reserve valued at zero during mint");
    }
}

contract ResidualAverageProbe is FrenSwapper {
    constructor(address pool, address token, address reserve, address collection, address pair, address ethHook)
        FrenSwapper(pool, token, reserve, collection, pair, ethHook)
    {}

    function average(uint256 imdIn, uint256 out) external {
        _average(imdIn, out);
    }
}

contract FrensAverageResidualRiskTest is Test {
    /// @dev 0cb9cbd74e81: a dust first sample prevents the full buy's same-block observation.
    function test_Risk_DustFirstPinsAverageAcrossOneHundredBlocks() public {
        ResidualAverageProbe s = new ResidualAverageProbe(
            FrensPlan.POOL_MANAGER,
            FrensPlan.IMD,
            FrensPlan.IMD6900,
            FrensPlan.FRENS_AT,
            FrensPlan.PAIR_HOOK,
            FrensPlan.POOL4_HOOK
        );
        uint256 rate = 70_000e18;
        s.average(1e18, rate);
        for (uint256 i; i < 100; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            s.average(1e12, 1e12 * 2 * rate / 1e18);
            uint256 afterDust = s.rateAverage();
            s.average(s.FULL_BUY(), s.FULL_BUY() * 2 * rate / 1e18);
            assertEq(s.rateAverage(), afterDust, "full buy never sampled");
        }
        assertGt(s.rateAverage(), rate);
        assertLt(s.rateAverage(), rate + rate / 1_000_000, "retained risk: still near the seed");
    }
}
