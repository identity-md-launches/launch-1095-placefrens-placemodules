// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {FrensCode} from "../src/FrensCode.sol";
import {FrensPlan} from "../src/FrensPlan.sol";
import {Placer, PlaceFrens, PlaceModules} from "../src/FrensPlacement.sol";
import {IMD6900Frens} from "../src/frens/IMD6900Frens.sol";
import {FrenSwapper} from "../src/frens/FrenSwapper.sol";
import {FrenMinter} from "../src/frens/FrenMinter.sol";
import {FrenWorkerGate} from "../src/frens/FrenWorkerGate.sol";
import {WorkerFrensRenderer} from "../src/frens/WorkerFrensRenderer.sol";
import {WorkerArt1, WorkerArt2} from "../src/art/WorkerArt.sol";
import {DeployFrens} from "../script/frens/DeployFrens.s.sol";
import {FrensRules} from "./frens/FrensRules.sol";
import {FrenArt} from "./frens/DataWriter.sol";
import {MockToken, NoZeroToken} from "./frens/IMD6900Frens.t.sol";

/// @dev Something else at the standard deployer's address: it refuses every creation
contract RefusingDeployer {
    fallback() external payable {
        revert("not here");
    }
}

/// @dev Something else at the standard deployer's address: it answers and creates nothing
contract SilentDeployer {
    fallback() external payable {}
}

/// @dev A deployer that creates, but under another salt scheme: the contract lands somewhere else
contract OtherSaltDeployer {
    fallback() external payable {
        bytes32 salt = keccak256(abi.encode(bytes32(msg.data[:32])));
        bytes memory init = msg.data[32:];
        address a;
        assembly ("memory-safe") {
            a := create2(0, add(init, 32), mload(init), salt)
        }
        require(a != address(0), "create2");
    }
}

/// @dev Claims to be a PlaceFrens whose frens are an account with no code
contract FakePlaced {
    function frens() external pure returns (address) {
        return address(0xBEEF);
    }
}

/// @dev What IMD's two launches do, from its own deployer, so the launches' actors are all known to the tests: the
///      collection (PlaceFrens, PlaceModules), then the art (WorkerArt1, WorkerArt2, WorkerFrensRenderer)
contract LaunchRunner {
    PlaceFrens public placeFrens;
    PlaceModules public placeModules;
    address public art1;
    address public art2;
    address public renderer;

    function launch() external {
        placeFrens = new PlaceFrens();
        placeModules = new PlaceModules(placeFrens);
        art1 = address(new WorkerArt1());
        art2 = address(new WorkerArt2());
        renderer = address(new WorkerFrensRenderer(art1, art2));
    }
}

/// @dev Like $IMD for these tests: explicit allowances only (Solady's mock otherwise lets Permit2 spend anything)
contract PlainImd is MockToken {
    constructor() MockToken("IMD") {}

    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }
}

/// @notice The launch's failure paths: a deployer that isn't the standard one, modules over the wrong frens, ETH sent
///         to the launch, a second launch, what nobody but the team wallet may do, and the collection before the team
///         wallet has set it up. Plus fuzzed properties of the price table and the quote the placed collection serves.
contract UnconfiguredFrensScript is DeployFrens {
    function _modules() internal pure override returns (address) {
        return address(0);
    }
}

contract FrensLaunchFailuresTest is Test, FrensRules {
    bytes constant CREATE2_DEPLOYER_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    address constant OWNER = FrensPlan.OWNER;

    function setUp() public {
        vm.etch(FrensPlan.CREATE2_DEPLOYER, CREATE2_DEPLOYER_CODE);
    }

    function _run(address imdDeployer) internal returns (LaunchRunner d) {
        vm.prank(imdDeployer);
        d = new LaunchRunner();
        d.launch();
    }

    function _create2(bytes32 salt, bytes memory init) internal pure returns (address) {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), FrensPlan.CREATE2_DEPLOYER, salt, keccak256(init))))
            )
        );
    }

    /* ── the standard deployer, or nothing ─────────────────────── */

    /// @dev Code at the standard deployer's address that refuses: the launch fails rather than landing elsewhere
    function test_RefusingDeployerFailsTheLaunch() public {
        vm.etch(FrensPlan.CREATE2_DEPLOYER, address(new RefusingDeployer()).code);
        vm.expectRevert(Placer.PlaceFailed.selector);
        new PlaceFrens();
        assertEq(FrensPlan.PRICES_AT.code.length, 0, "nothing placed");
    }

    /// @dev Code that answers and creates nothing: the launch notices the planned address stayed empty
    function test_SilentDeployerFailsTheLaunch() public {
        vm.etch(FrensPlan.CREATE2_DEPLOYER, address(new SilentDeployer()).code);
        vm.expectRevert(Placer.PlaceFailed.selector);
        new PlaceFrens();
    }

    /// @dev A deployer with another salt scheme puts the contract somewhere else: the launch refuses, it never adopts
    ///      a contract that isn't at the planned address
    function test_OtherSaltSchemeFailsTheLaunch() public {
        vm.etch(FrensPlan.CREATE2_DEPLOYER, address(new OtherSaltDeployer()).code);
        vm.expectRevert(Placer.PlaceFailed.selector);
        new PlaceFrens();
    }

    /// @dev The modules refuse frens that aren't a collection (nothing at the address the placer names)
    function test_ModulesNeedTheCollection() public {
        PlaceFrens fake = PlaceFrens(address(new FakePlaced()));
        vm.expectRevert();
        new PlaceModules(fake);
        vm.expectRevert();
        new PlaceModules(PlaceFrens(address(0xdead)));
        assertEq(FrensPlan.SWAPPER_AT.code.length, 0, "a failed launch places nothing");
    }

    /// @dev PlaceFrens is placed, then the frens' address is taken over by an unrelated contract before PlaceModules
    ///      runs (a fresh chain: the launch's own CREATE2 can't be pre-empted, so this only models a corrupted state):
    ///      the minter's constructor reads the frens and fails
    function test_ModulesFailOverCorruptedFrens() public {
        PlaceFrens pf = new PlaceFrens();
        vm.etch(pf.frens(), address(new SilentDeployer()).code);
        // try, not vm.expectRevert over `new` (see test_WrongArtFailsTheArtLaunch)
        try new PlaceModules(pf) {
            assertTrue(false, "modules over a corrupted collection");
        } catch {}
    }

    /// @dev The art launch refuses art that isn't the exact code WorkerArtIndex was generated from (the renderer would
    ///      draw nothing over it, every read checks the chunk's code hash): the chunks swapped, one with no code, or
    ///      another data contract. The right order draws the new art.
    function test_WrongArtFailsTheArtLaunch() public {
        address a1 = address(new WorkerArt1());
        address a2 = address(new WorkerArt2());
        bytes[] memory other = new bytes[](1);
        other[0] = new bytes(1024);
        address data = new FrenArt().write(other)[0];
        address none = makeAddr("no code");
        address[2][5] memory wrong = [[a2, a1], [a1, none], [none, a2], [a1, data], [a1, a1]];
        // not vm.expectRevert over `new`: with forge's dynamic test linking a creation is a cheatcode call, and an
        // expected revert there ends the test early, before anything after it is checked
        for (uint256 i; i < wrong.length; ++i) {
            try new WorkerFrensRenderer(wrong[i][0], wrong[i][1]) {
                assertTrue(false, "the launch took the wrong art");
            } catch (bytes memory err) {
                assertEq(bytes4(err), WorkerFrensRenderer.BadArt.selector, "BadArt");
            }
        }
        // the right order draws the new art (the palettes need nothing from the swarm)
        WorkerFrensRenderer r = new WorkerFrensRenderer(a1, a2);
        assertEq(r.art1(), a1);
        assertEq(r.art2(), a2);
        assertEq(r.palette(0).length, 1024);
    }

    /* ── ETH and repeats ───────────────────────────────────────── */

    function test_LaunchContractsTakeNoEth() public {
        LaunchRunner d = _run(makeAddr("IMD's deployer"));
        address[2] memory launch = [address(d.placeFrens()), address(d.placeModules())];
        for (uint256 i; i < 2; ++i) {
            vm.deal(address(this), 1 ether);
            (bool ok,) = launch[i].call{value: 1}("");
            assertFalse(ok, "no ETH into the launch");
            (ok,) = launch[i].call{value: 0}(abi.encodeWithSignature("anything()"));
            assertFalse(ok, "no fallback");
            assertEq(launch[i].balance, 0);
        }
    }

    /// @dev A second launch on Ethereum finds everything placed and takes it as it is: the same frens, the same
    ///      modules, their state untouched; only the art launch's contracts are new
    function test_SecondLaunchReusesWhatIsPlaced() public {
        LaunchRunner first = _run(makeAddr("first deployer"));
        IMD6900Frens f = IMD6900Frens(payable(first.placeFrens().frens()));
        vm.prank(OWNER);
        f.setMintOpen(true);
        LaunchRunner second = _run(makeAddr("second deployer"));
        assertEq(second.placeFrens().frens(), address(f));
        assertEq(second.placeFrens().prices(), first.placeFrens().prices());
        assertEq(second.placeModules().swapper(), first.placeModules().swapper());
        assertEq(second.placeModules().minter(), first.placeModules().minter());
        assertEq(second.placeModules().gate(), first.placeModules().gate());
        assertTrue(second.renderer() != first.renderer(), "a new renderer");
        assertTrue(f.mintOpen(), "the state of the first launch's frens is untouched");
        assertEq(f.owner(), OWNER);
    }

    /// @dev On a fresh chain, two launches make two collections, the same code at different addresses
    function test_FreshChainLaunchesAreIndependent() public {
        vm.etch(FrensPlan.CREATE2_DEPLOYER, "");
        LaunchRunner a = _run(makeAddr("first"));
        LaunchRunner b = _run(makeAddr("second"));
        assertTrue(a.placeFrens().frens() != b.placeFrens().frens());
        assertEq(a.placeFrens().prices().codehash, b.placeFrens().prices().codehash, "the same price table");
        // the collection's code differs only by its immutables (the price table's address): the same length, the
        // same prices, the same owner
        assertEq(a.placeFrens().frens().code.length, b.placeFrens().frens().code.length, "the same collection");
        assertEq(
            IMD6900Frens(payable(b.placeFrens().frens())).priceOf(2221),
            IMD6900Frens(payable(a.placeFrens().frens())).priceOf(2221)
        );
        assertEq(IMD6900Frens(payable(b.placeFrens().frens())).owner(), OWNER);
        assertEq(a.placeModules().swapper().code.length, b.placeModules().swapper().code.length);
        assertEq(
            FrenSwapper(payable(b.placeModules().swapper())).frens(), b.placeFrens().frens(), "each wired to its own"
        );
        assertEq(address(FrenMinter(payable(b.placeModules().minter())).frens()), b.placeFrens().frens());
        assertEq(FrenWorkerGate(b.placeModules().gate()).frens(), b.placeFrens().frens());
        assertEq(FrensPlan.FRENS_AT.code.length, 0, "nothing at the Ethereum address");
    }

    /// @dev The script that wires the frens after the launch refuses a chain where they aren't placed
    function test_ScriptRefusesAnUnplacedChain() public {
        vm.etch(FrensPlan.CREATE2_DEPLOYER, "");
        DeployFrens s = new UnconfiguredFrensScript();
        vm.expectRevert(bytes("MODULES must be the collection launch's PlaceModules"));
        s.placed();
        _run(makeAddr("fresh chain deployer"));
        vm.expectRevert(bytes("MODULES must be the collection launch's PlaceModules"));
        s.placed(); // the fresh chain's addresses aren't the plan's
    }

    /* ── the launch keeps no role ──────────────────────────────── */

    /// @dev Nothing that took part in the launch (IMD's deployer, the launch contracts, the CREATE2 deployer, the art,
    ///      the price table) holds any role on the frens or the gate, or can reach a privileged setting
    function test_NoLaunchActorHoldsARole() public {
        address imdDeployer = makeAddr("IMD's deployer");
        LaunchRunner d = _run(imdDeployer);
        PlaceFrens pf = d.placeFrens();
        PlaceModules pm = d.placeModules();
        IMD6900Frens f = IMD6900Frens(payable(pf.frens()));
        FrenWorkerGate gate = FrenWorkerGate(pm.gate());
        address[9] memory actors = [
            imdDeployer,
            address(d),
            address(pf),
            address(pm),
            FrensPlan.CREATE2_DEPLOYER,
            d.art1(),
            d.art2(),
            pf.prices(),
            d.renderer()
        ];
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[i];
            assertTrue(f.owner() != a && f.governor() != a && f.keeper() != a && f.relayer() != a, "no role");
            assertTrue(gate.owner() != a, "no gate role");
            vm.startPrank(a);
            vm.expectRevert(Ownable.Unauthorized.selector);
            f.setMintOpen(true);
            vm.expectRevert(Ownable.Unauthorized.selector);
            f.setModules(address(1), address(2));
            vm.expectRevert(Ownable.Unauthorized.selector);
            f.setRoles(a, a, a);
            vm.expectRevert(Ownable.Unauthorized.selector);
            f.setGovernor(a);
            vm.expectRevert(Ownable.Unauthorized.selector);
            f.setRenderer(a);
            vm.expectRevert(Ownable.Unauthorized.selector);
            f.freezeArt();
            vm.expectRevert(Ownable.Unauthorized.selector);
            f.setTransferValidator(address(0));
            vm.expectRevert(Ownable.Unauthorized.selector);
            f.setParams(1, 0, 0);
            vm.expectRevert(Ownable.Unauthorized.selector);
            f.setRoyalty(0);
            vm.expectRevert(Ownable.Unauthorized.selector);
            f.sealTraits();
            vm.expectRevert(Ownable.Unauthorized.selector);
            f.transferOwnership(a);
            vm.expectRevert(IMD6900Frens.NotKeeper.selector);
            f.approveJob(1, 1, block.timestamp, IMD6900Frens.Quote("", 0, "", 0, 0, "", 0));
            vm.expectRevert(Ownable.Unauthorized.selector);
            gate.setWlRoot(bytes32(uint256(1)));
            vm.expectRevert(Ownable.Unauthorized.selector);
            gate.openPublic();
            vm.expectRevert(FrenWorkerGate.OnlyFrens.selector);
            gate.spend(a, 1);
            vm.stopPrank();
        }
        // and the team wallet holds them all
        assertEq(f.owner(), OWNER);
        assertEq(f.governor(), OWNER);
        assertEq(gate.owner(), OWNER);
    }

    /* ── before the team wallet's setup ────────────────────────── */

    /// @dev Right after the launch nobody mints: the public finds the mint closed, the team wallet finds the traits
    ///      unsealed; the floor's buys find no swapper. Then the team wallet wires it as setup() does, and the
    ///      collection draws through the launch's renderer: offline, without the swarm's chunks, it draws nothing
    ///      rather than something wrong.
    function test_CollectionWaitsForTheTeamWallet() public {
        vm.etch(FrensPlan.IMD, address(new PlainImd()).code);
        vm.etch(FrensPlan.IMD6900, address(new NoZeroToken()).code);
        vm.etch(FrensPlan.IDENTITY, address(new MockToken("identity")).code);
        LaunchRunner d = _run(makeAddr("IMD's deployer"));
        IMD6900Frens f = IMD6900Frens(payable(d.placeFrens().frens()));
        PlaceModules pm = d.placeModules();
        address minter = makeAddr("a minter");
        MockToken(FrensPlan.IMD).mint(minter, 100e18);
        MockToken(FrensPlan.IMD).mint(OWNER, 100e18);
        vm.prank(minter);
        vm.expectRevert(IMD6900Frens.MintClosed.selector);
        f.requestMint(1, type(uint256).max);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900Frens.TraitsNotSealed.selector);
        f.requestMintFor(FrensPlan.IMD6900, 1, type(uint256).max);
        vm.expectRevert(IMD6900Frens.Cap.selector);
        f.buyFloor(0); // nothing waiting, no swapper
        vm.expectRevert(bytes4(keccak256("TokenDoesNotExist()")));
        f.tokenURI(1);

        // the team wallet's setup (script/frens/DeployFrens.s.sol setup()), call for call
        vm.startPrank(OWNER);
        f.setRenderer(d.renderer());
        f.setModules(pm.swapper(), pm.gate());
        _rules(f, [uint16(1598), 312, 312]);
        f.sealTraits();
        MockToken(FrensPlan.IMD).approve(address(f), type(uint256).max);
        uint256 id = f.requestMintFor(FrensPlan.IMD6900, 1, type(uint256).max); // the curve's first fren, closed mint
        vm.stopPrank();
        assertEq(id, 1);
        assertEq(f.ownerOf(1), FrensPlan.IMD6900);
        assertEq(f.renderer(), d.renderer());
        assertEq(f.floorImd(), 0.6901e18 - 0.5e18, "the floor waits in $IMD: the real swapper has no pool here");
        assertEq(f.jobBudget(), 0.5e18);
        vm.expectRevert(WorkerFrensRenderer.BadArt.selector);
        f.tokenURI(1); // the swarm's faces aren't on this chain: no card, never a wrong one
        vm.prank(minter);
        vm.expectRevert(IMD6900Frens.MintClosed.selector);
        f.requestMint(1, type(uint256).max); // still closed for the public
    }

    /// @dev The collection's constructor refuses a price table of the wrong length: a launch over a bad table fails
    ///      instead of serving prices
    function test_CollectionRefusesAShortPriceTable() public {
        bytes[] memory b = new bytes[](2);
        b[0] = new bytes(3 * 2222 - 1);
        b[1] = new bytes(3 * 2222 + 1);
        address[] memory tables = new FrenArt().write(b);
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(IMD6900Frens.BadTraits.selector);
            new IMD6900Frens(
                OWNER,
                FrensPlan.IMD,
                FrensPlan.IMD6900,
                FrensPlan.IDENTITY,
                FrensPlan.PERMIT2,
                FrensPlan.X402_PROXY,
                FrensPlan.IMD_PAY_TO,
                FrensPlan.KEEPER,
                FrensPlan.RELAYER,
                tables[i]
            );
        }
        vm.expectRevert(IMD6900Frens.BadTraits.selector);
        new IMD6900Frens(
            OWNER,
            FrensPlan.IMD,
            FrensPlan.IMD6900,
            FrensPlan.IDENTITY,
            FrensPlan.PERMIT2,
            FrensPlan.X402_PROXY,
            FrensPlan.IMD_PAY_TO,
            FrensPlan.KEEPER,
            FrensPlan.RELAYER,
            address(0xdead)
        );
    }

    /* ── the price table and the quote, fuzzed on the placed collection ── */

    /// @dev Every one of the 2222 prices the placed collection serves is the swarm's table's, the curve never falls,
    ///      and all of it adds up to the curve's total plus the seven nudges
    function test_EveryPriceIsTheTables() public {
        PlaceFrens pf = new PlaceFrens();
        IMD6900Frens f = IMD6900Frens(payable(pf.frens()));
        bytes memory swarm = vm.readFileBinary("script/frens/price/prices-swarm.bin");
        uint256 total;
        uint256 last;
        for (uint256 n; n < 2222; ++n) {
            uint256 units =
                uint256(uint8(swarm[3 * n])) << 16 | uint256(uint8(swarm[3 * n + 1])) << 8 | uint8(swarm[3 * n + 2]);
            uint256 p = f.priceOf(n);
            assertEq(p, units * 1e14, "the table's price");
            assertGe(p, last, "the curve never falls");
            last = p;
            total += p;
        }
        assertEq(f.priceOf(0), 0.6901e18);
        assertEq(f.priceOf(2221), 3.2378e18, "the plateau");
        assertEq(total, 5422.3473e18, "5422.3466 on the curve, seven nudges of 0.0001");
        assertEq(f.quote(2222), total, "all 2222 at once cost the whole table");
    }

    /// @dev Past the table there is no price: a read beyond it returns nothing, and the quote refuses to go there
    function test_NoPricePastTheTable() public {
        PlaceFrens pf = new PlaceFrens();
        IMD6900Frens f = IMD6900Frens(payable(pf.frens()));
        assertEq(f.priceOf(2222), 0, "EXTCODECOPY past the code reads zeros");
        vm.expectRevert(IMD6900Frens.SoldOut.selector);
        f.quote(2223);
        vm.expectRevert(IMD6900Frens.SoldOut.selector);
        f.quote(0);
        vm.expectRevert(IMD6900Frens.SoldOut.selector);
        f.quote(type(uint256).max);
    }

    /// forge-config: default.fuzz.runs = 512
    /// @dev Before anyone holds a fren the quote is the curve: the sum of the next `count` prices, and `count` of
    ///      the dearest is never more than the whole table
    function testFuzz_QuoteIsTheCurveBeforeAnyoneHolds(uint256 count) public {
        count = bound(count, 1, 69);
        PlaceFrens pf = new PlaceFrens();
        IMD6900Frens f = IMD6900Frens(payable(pf.frens()));
        uint256 sum;
        for (uint256 i; i < count; ++i) {
            sum += f.priceOf(i);
        }
        assertEq(f.quote(count), sum);
        assertLe(f.quote(count), count * 3.2378e18);
        assertGe(f.quote(count), count * 0.6901e18);
    }

    /// forge-config: default.fuzz.runs = 512
    /// @dev Any 24 bits: the placed collection (sealed with the launch rules) says 0 for a fren and 1 for what isn't
    ///      one: a trait past its values, bit 23, or a hat on anything but the cyborg pepe
    function testFuzz_CheckKnowsAFren(uint24 combo, uint8 tier) public {
        tier = uint8(bound(tier, 0, 3));
        PlaceFrens pf = new PlaceFrens();
        IMD6900Frens f = IMD6900Frens(payable(pf.frens()));
        vm.startPrank(OWNER);
        _rules(f, [uint16(1598), 312, 312]);
        f.sealTraits();
        vm.stopPrank();
        uint8[8] memory values = [3, 13, 4, 3, 6, 3, 12, 16];
        uint8[8] memory shifts = [0, 2, 6, 8, 10, 13, 15, 19];
        uint8[8] memory bits = [2, 4, 2, 2, 3, 2, 4, 4];
        bool fren = combo >> 23 == 0;
        for (uint256 t; t < 8; ++t) {
            if ((combo >> shifts[t]) & ((1 << bits[t]) - 1) >= values[t]) fren = false;
        }
        if ((combo & 3) != 0 && ((combo >> 13) & 3) != 0) fren = false;
        uint8 code = f.check(combo, tier);
        if (!fren) {
            assertEq(code, 1, "not a fren");
        } else {
            assertTrue(code == 0 || code == 4, "a fren: allowed, or its tier too low");
            assertEq(f.check(combo, 3), 0, "tier 3 may take any fren while nothing is taken");
        }
    }

    /// forge-config: default.fuzz.runs = 256
    /// @dev The frens' and the swapper's addresses follow from the salts: any other salt lands elsewhere
    function testFuzz_OtherSaltsLandElsewhere(bytes32 salt) public pure {
        vm.assume(salt != FrensPlan.FRENS_SALT && salt != FrensPlan.SWAPPER_SALT);
        bytes memory frensInit = abi.encodePacked(
            FrensCode.FRENS,
            abi.encode(
                FrensPlan.OWNER,
                FrensPlan.IMD,
                FrensPlan.IMD6900,
                FrensPlan.IDENTITY,
                FrensPlan.PERMIT2,
                FrensPlan.X402_PROXY,
                FrensPlan.IMD_PAY_TO,
                FrensPlan.KEEPER,
                FrensPlan.RELAYER,
                FrensPlan.PRICES_AT
            )
        );
        assertTrue(_create2(salt, frensInit) != FrensPlan.FRENS_AT);
    }

    /// @dev One changed byte of the collection's constructor arguments (another owner) moves the frens away from 0x6900…
    function test_AnotherOwnerMovesTheFrens() public pure {
        bytes memory other = abi.encodePacked(
            FrensCode.FRENS,
            abi.encode(
                address(uint160(FrensPlan.OWNER) + 1),
                FrensPlan.IMD,
                FrensPlan.IMD6900,
                FrensPlan.IDENTITY,
                FrensPlan.PERMIT2,
                FrensPlan.X402_PROXY,
                FrensPlan.IMD_PAY_TO,
                FrensPlan.KEEPER,
                FrensPlan.RELAYER,
                FrensPlan.PRICES_AT
            )
        );
        assertTrue(_create2(FrensPlan.FRENS_SALT, other) != FrensPlan.FRENS_AT);
    }
}
