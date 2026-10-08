// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FrensReviewBase, FrensAllowanceToken, FrensSlot0Stub} from "./FrensLaunchReview.t.sol";
import {MockToken, MockPermit2, MockSwapper, MockRenderer} from "./frens/IMD6900Frens.t.sol";
import {PlaceFrens, PlaceModules} from "../src/FrensPlacement.sol";
import {FrensPlan} from "../src/FrensPlan.sol";
import {IMD6900Frens} from "../src/frens/IMD6900Frens.sol";
import {FrenSwapper} from "../src/frens/FrenSwapper.sol";
import {FrenMinter} from "../src/frens/FrenMinter.sol";
import {FrenWorkerGate} from "../src/frens/FrenWorkerGate.sol";
import {DeployFrens, IStrategyMin, IPairExemption} from "../script/frens/DeployFrens.s.sol";

/// @dev Inject script inputs without process-global environment mutations between parallel tests.
contract DeployFrensHarness is DeployFrens {
    address internal modulesInput;
    address internal rendererInput;

    constructor(address modules_, address renderer_) {
        modulesInput = modules_;
        rendererInput = renderer_;
    }

    function setModulesInput(address modules_) external {
        modulesInput = modules_;
    }

    function _modules() internal view override returns (address) {
        return modulesInput;
    }

    function _renderer() internal view override returns (address) {
        return rendererInput;
    }
}

/// @notice Script mitigations and explicit reproductions of risks retained in the pinned bytecode.
contract FrensLaunchAdaptationTest is FrensReviewBase {
    DeployFrensHarness internal script;
    PlaceFrens internal pf;
    PlaceModules internal pm;
    IMD6900Frens internal frens;
    MockToken internal imd;
    MockToken internal reserveToken;
    MockPermit2 internal permit2;

    function setUp() public {
        vm.chainId(1);
        vm.etch(FrensPlan.CREATE2_DEPLOYER, DEPLOYER_CODE);
        vm.etch(FrensPlan.IMD, address(new FrensAllowanceToken()).code);
        vm.etch(FrensPlan.IMD6900, address(new MockToken("reserve")).code);
        vm.etch(FrensPlan.IDENTITY, address(new MockToken("identity")).code);
        vm.etch(FrensPlan.PERMIT2, address(new MockPermit2()).code);
        imd = MockToken(FrensPlan.IMD);
        reserveToken = MockToken(FrensPlan.IMD6900);
        permit2 = MockPermit2(FrensPlan.PERMIT2);
        pf = PlaceFrens(deployCode("FrensPlacement.sol:PlaceFrens"));
        pm = PlaceModules(deployCode("FrensPlacement.sol:PlaceModules", abi.encode(pf)));
        frens = IMD6900Frens(payable(pf.frens()));
        script = new DeployFrensHarness(address(pm), address(new MockRenderer()));
        _distributor(true);
        _exempt(pm.swapper(), true);
        imd.mint(FrensPlan.OWNER, 10_000e18);
        imd.mint(FrensPlan.IMD6900, 10_000e18); // strategy's tier in this test
        vm.prank(FrensPlan.OWNER);
        imd.approve(address(frens), type(uint256).max);
    }

    function _distributor(bool value) internal {
        vm.mockCall(FrensPlan.IMD6900, abi.encodeCall(IStrategyMin.isDistributor, (address(frens))), abi.encode(value));
    }

    function _exempt(address swapper, bool value) internal {
        vm.mockCall(FrensPlan.PAIR_HOOK, abi.encodeCall(IPairExemption.feeExempt, (swapper)), abi.encode(value));
    }

    function _first() internal returns (uint256 id) {
        uint256 paid = frens.quote(2);
        vm.prank(FrensPlan.OWNER);
        id = frens.requestMintFor(FrensPlan.IMD6900, 2, paid);
    }

    function _pool(uint160 price) internal returns (FrensSlot0Stub pool) {
        vm.etch(FrensPlan.POOL_MANAGER, address(new FrensSlot0Stub()).code);
        pool = FrensSlot0Stub(FrensPlan.POOL_MANAGER);
        pool.setPrice(price);
        vm.mockCall(
            FrensPlan.POOL_MANAGER,
            abi.encodeWithSignature("exttload(bytes32)", bytes32(uint256(keccak256("Unlocked")) - 1)),
            abi.encode(bytes32(0))
        );
    }

    function _replaceModulesAtPrice(uint160 price) internal returns (FrensSlot0Stub pool) {
        // Rehearse a launch starting with no swapper, as in a fresh Ethereum placement.
        vm.etch(FrensPlan.SWAPPER_AT, "");
        vm.setNonceUnsafe(FrensPlan.SWAPPER_AT, 0);
        pool = _pool(price);
        pm = PlaceModules(deployCode("FrensPlacement.sol:PlaceModules", abi.encode(pf)));
        script.setModulesInput(address(pm));
    }

    function test_SetupPausesBeforeFirstMintEvenWhenAlreadyDistributor() public {
        script.setup();
        assertTrue(frens.traitsSealed());
        assertFalse(frens.mintOpen());
        assertEq(frens.maxImdPerBuy(), 0);
        assertEq(frens.maxEthPerBuy(), 0);
        vm.deal(address(frens), 0.25 ether);
        vm.expectRevert(IMD6900Frens.Cap.selector);
        frens.buyFloorWithEth(0.25 ether, 0);
    }

    function test_OpenAndResumeRefuseAnOwnerlessFloor() public {
        script.setup();
        vm.expectRevert(bytes("mint the strategy's first frens before opening or resuming"));
        script.open();
        vm.expectRevert(bytes("mint the strategy's first frens before opening or resuming"));
        script.resume();
        assertFalse(frens.mintOpen());
        assertEq(frens.maxEthPerBuy(), 0);
    }

    function test_BootstrapThenOpenAndResume() public {
        script.setup();
        _first();
        assertEq(frens.balanceOf(FrensPlan.IMD6900), 2);
        script.open();
        script.resume();
        assertTrue(frens.mintOpen());
        assertEq(frens.maxImdPerBuy(), 50e18);
        assertEq(frens.maxEthPerBuy(), 0.25 ether);
        assertEq(frens.swapper(), pm.swapper());
        assertEq(frens.workerGate(), pm.gate());
    }

    function test_FirstFrensRequiresPausedBuysAndNonzeroCount() public {
        FrenMinter minter = FrenMinter(payable(pm.minter()));
        vm.expectRevert(bytes("run setup to pause floor buys first"));
        script.firstFrens(frens, minter, 2, 0);
        script.setup();
        vm.expectRevert(bytes("no first frens requested"));
        script.firstFrens(frens, minter, 0, 0);
    }

    /// @dev The ea109756 repair: a legitimate price move while buys are paused must not lock out activation.
    function test_OpenAndResumeWarnWhenAverageLags() public {
        FrensSlot0Stub pool = _replaceModulesAtPrice(uint160((uint256(1) << 96) / 265));
        script.setup();
        _first();
        pool.setPrice(uint160((uint256(1) << 96) / 26));
        FrenSwapper swapper = FrenSwapper(payable(pm.swapper()));
        assertGt(swapper.rateAverage(), 2 * swapper.spotRate());
        script.open();
        script.resume();
        assertTrue(frens.mintOpen());
        assertEq(frens.maxImdPerBuy(), 50e18);
        assertEq(frens.maxEthPerBuy(), 0.25 ether);
    }

    function test_ResumeRequiresDistributorAndActualSwapperExemption() public {
        script.setup();
        _first();
        _distributor(false);
        vm.expectRevert(bytes("not an IMD6900 distributor yet: the batch hasn't landed"));
        script.resume();
        _distributor(true);
        _exempt(pm.swapper(), false);
        vm.expectRevert(bytes("actual swapper is not fee-exempt"));
        script.resume();
        assertEq(frens.maxEthPerBuy(), 0);
    }

    function test_OpenAndResumeRejectChangedWiring() public {
        script.setup();
        _first();
        address replacement = address(new MockSwapper(reserveToken, imd));
        address gate = pm.gate();
        vm.prank(FrensPlan.OWNER);
        frens.setModules(replacement, gate);
        vm.expectRevert(bytes("modules differ from the launch"));
        script.open();
        vm.expectRevert(bytes("modules differ from the launch"));
        script.resume();
    }

    function test_PlacedRejectsMissingOrWrongModules() public {
        script.setModulesInput(address(0));
        vm.expectRevert(bytes("MODULES must be the collection launch's PlaceModules"));
        script.placed();
        script.setModulesInput(makeAddr("no modules"));
        vm.expectRevert(bytes("MODULES must be the collection launch's PlaceModules"));
        script.placed();
        script.setModulesInput(address(pf)); // code, but not PlaceModules
        vm.expectRevert();
        script.placed();
    }

    function test_PlacedReportsTheLaunchModules() public {
        (address f, address s, address m, address g) = script.placed();
        assertEq(f, pm.frens());
        assertEq(s, pm.swapper());
        assertEq(m, pm.minter());
        assertEq(g, pm.gate());
    }

    function test_PlacedRejectsWrongCollectionAndForeignDependencies() public {
        vm.mockCall(address(pm), abi.encodeCall(pm.frens, ()), abi.encode(address(pm)));
        vm.expectRevert(bytes("wrong Ethereum collection"));
        script.placed();
        vm.mockCall(address(pm), abi.encodeCall(pm.frens, ()), abi.encode(address(frens)));
        vm.mockCall(pm.swapper(), abi.encodeWithSignature("frens()"), abi.encode(address(pm)));
        vm.expectRevert(bytes("modules belong to another collection"));
        script.placed();
    }

    function test_SetupUsesTheLaunchsReplacementSwapper() public {
        FrensSlot0Stub pool = _replaceModulesAtPrice(uint160((uint256(1) << 96) / 26));
        pool.setPrice(uint160((uint256(1) << 96) / 265));
        vm.roll(block.number + 1);
        pm = PlaceModules(deployCode("FrensPlacement.sol:PlaceModules", abi.encode(pf)));
        script.setModulesInput(address(pm));
        assertNotEq(pm.swapper(), FrensPlan.SWAPPER_AT);
        script.setup();
        assertEq(frens.swapper(), pm.swapper());
        // The queued batch exempts the planned address, which is insufficient for this replacement.
        _first();
        _exempt(FrensPlan.SWAPPER_AT, true);
        _exempt(pm.swapper(), false);
        vm.expectRevert(bytes("actual swapper is not fee-exempt"));
        script.resume();
        _exempt(pm.swapper(), true);
        script.resume();
    }

    function test_Risk_LaunchBlockPushSeedsSwapperAndSetupRejectsAfterPriceReturns() public {
        FrensSlot0Stub pool = _replaceModulesAtPrice(uint160((uint256(1) << 96) / 26));
        FrenSwapper swapper = FrenSwapper(payable(pm.swapper()));
        assertEq(pm.swapper(), FrensPlan.SWAPPER_AT);
        assertApproxEqAbs(swapper.rateAverage(), 676e18, 1);
        pool.setPrice(uint160((uint256(1) << 96) / 265));
        vm.roll(block.number + 1);
        assertGt(swapper.spotRate(), swapper.floorRate() * 100);
        vm.expectRevert(bytes("swapper average outside spot band"));
        script.setup();
        assertFalse(frens.traitsSealed());
    }

    function _mockFloor() internal returns (MockSwapper swapper) {
        script.setup();
        swapper = new MockSwapper(reserveToken, imd);
        vm.startPrank(FrensPlan.OWNER);
        frens.setModules(address(swapper), address(0));
        frens.setParams(1, 50e18, 0.25 ether);
        vm.stopPrank();
    }

    function test_Risk_FirstMintCapturesExistingFloorIfRunbookIsBypassed() public {
        MockSwapper swapper = _mockFloor();
        vm.deal(address(frens), 0.25 ether);
        frens.buyFloorWithEth(0.25 ether, 0);
        imd.mint(address(frens), 100e18);
        assertEq(frens.totalMinted(), 0);
        uint256 paid = frens.quote(2);
        _first();
        vm.prank(FrensPlan.IMD6900);
        (uint256 got, uint256 gotImd) = frens.recycle(1);
        uint256 back = gotImd + got * 1e18 / swapper.floorRate();
        assertGt(back, paid, "pinned collection still has the pre-first-mint exposure");
    }

    function test_FirstFrensBeforeFeesPreventsPublicFloorCapture() public {
        script.setup();
        _first();
        MockSwapper swapper = new MockSwapper(reserveToken, imd);
        vm.startPrank(FrensPlan.OWNER);
        frens.setModules(address(swapper), address(0));
        frens.setParams(1, 50e18, 0.25 ether);
        frens.setMintOpen(true);
        vm.stopPrank();
        vm.deal(address(frens), 0.25 ether);
        frens.buyFloorWithEth(0.25 ether, 0);
        imd.mint(address(frens), 100e18);
        address buyer = makeAddr("public buyer");
        imd.mint(buyer, 10_000e18);
        uint256 paid = frens.quote(2);
        vm.startPrank(buyer);
        imd.approve(address(frens), paid);
        frens.requestMint(2, paid);
        (uint256 got, uint256 gotImd) = frens.recycle(3);
        vm.stopPrank();
        assertLe(gotImd + got * 1e18 / swapper.floorRate(), paid);
    }

    /// @dev Fixed after IMD's audit (the judge's low finding): a payment over a Permit2 nonce already spent is refused,
    ///      so its 0.50 $IMD can't be stranded in the allowance; the request's job money stays to pay a fresh nonce
    function test_Fix_SpentNonceIsRefused() public {
        script.setup();
        uint256 id = _first();
        permit2.spend(address(frens), 42);
        uint256 expiry = block.timestamp + 600;
        IMD6900Frens.Quote memory q =
            IMD6900Frens.Quote("audit", bytes32("scope"), "1", bytes32("q"), bytes32("p"), "job.open", expiry);
        vm.prank(FrensPlan.KEEPER);
        vm.expectRevert(IMD6900Frens.BadJob.selector);
        frens.approveJob(id, 42, expiry, q);
        assertEq(imd.allowance(address(frens), address(permit2)), 0, "nothing approved");
        assertEq(frens.jobBudget(), 0.5e18, "the job money is still there");
        vm.prank(FrensPlan.KEEPER);
        frens.approveJob(id, 43, expiry, q);
        assertEq(imd.allowance(address(frens), address(permit2)), 0.5e18, "a fresh nonce pays the job");
    }

    function test_Risk_UnsupportedRoyaltyTokenHasNoFloorRoute() public {
        MockSwapper swapper = _mockFloor();
        _first();
        MockToken other = new MockToken("unsupported royalty");
        (address receiver,) = frens.royaltyInfo(1, 1_000e6);
        other.mint(receiver, 1_000e6);
        vm.roll(block.number + 2);
        imd.mint(address(frens), 1e18);
        frens.buyFloor(0);
        vm.deal(address(frens), 0.25 ether);
        frens.buyFloorWithEth(0.25 ether, 0);
        vm.prank(FrensPlan.IMD6900);
        frens.recycle(1);
        assertGt(frens.reserve(), 0);
        assertEq(other.balanceOf(receiver), 1_000e6);
        assertEq(other.balanceOf(address(swapper)), 0);
    }
}
