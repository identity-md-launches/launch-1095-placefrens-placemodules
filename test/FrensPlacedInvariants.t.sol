// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {FrensPlan} from "../src/FrensPlan.sol";
import {PlaceFrens} from "../src/FrensPlacement.sol";
import {IMD6900Frens, IFrenSwapper} from "../src/frens/IMD6900Frens.sol";
import {FrensRules} from "./frens/FrensRules.sol";
import {MockToken, NoZeroToken, MockPermit2, MockSwapper} from "./frens/IMD6900Frens.t.sol";
import {PlainImd} from "./FrensLaunchFailures.t.sol";

/// @dev Drives the collection the launch placed at 0x6900… with bounded inputs from several wallets: mints, reveals
///      (the relayer's vouchers), recycles, treasury buys, trades, floor buys in $IMD and ETH, donations, job
///      approvals and settlements, retries, the governor's parameters, the pool's rate. Every call it makes is
///      expected to succeed (or to fail for the reason it computed first): an unexpected revert is a failure.
contract PlacedFrensHandler is CommonBase, StdCheats, StdUtils, StdAssertions, FrensRules {
    uint256 internal constant SUPPLY = 2222;
    uint256 internal constant JOB = 0.5e18;
    address internal constant OWNER = FrensPlan.OWNER;

    IMD6900Frens public immutable frens;
    MockToken public immutable imd;
    NoZeroToken public immutable imd6900;
    MockPermit2 public immutable permit2;
    MockSwapper public immutable swapper;
    uint256 internal immutable relayerKey;
    address public immutable keeper;
    address public immutable payTo;
    address public immutable poor; // a wallet that mints at tier 0
    address internal immutable sink;

    address[] public actors; // wallets that mint at tier 3
    uint256[] public requestIds;
    mapping(uint256 => uint24[]) internal combosOf; // what the relayer will reveal each request as
    uint256 internal pepes;
    uint256 internal mumus;
    uint256 internal bobos;
    uint256 internal nonces = 1;

    // ghosts
    uint256 public ghost6900In; // IMD6900 the floor bought or was paid (reserve in)
    uint256 public ghost6900Out; // IMD6900 recycles paid (reserve out)
    uint256 public ghost6900Donated; // IMD6900 sent to the contract outside the floor
    uint256 public ghostImdUnswept; // $IMD sent to the contract and not yet swept into the floor
    uint256 public ghostEthIn;
    uint256 public ghostEthSpent;
    uint256 public ghostRevealed;
    uint256 public ghostFloorBuys;
    mapping(bytes32 => uint256) public calls;

    constructor(IMD6900Frens f, MockSwapper s, uint256 relayerKey_, address keeper_, address payTo_) {
        frens = f;
        swapper = s;
        imd = MockToken(f.imd());
        imd6900 = NoZeroToken(f.imd6900());
        permit2 = MockPermit2(f.permit2());
        relayerKey = relayerKey_;
        keeper = keeper_;
        payTo = payTo_;
        sink = makeAddr("sink");
        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string.concat("rich ", vm.toString(i))));
        }
        poor = makeAddr("poor");
        for (uint256 i; i <= actors.length; ++i) {
            address a = i < actors.length ? actors[i] : poor;
            vm.startPrank(a);
            imd.approve(address(f), type(uint256).max);
            imd6900.approve(address(f), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function requestCount() external view returns (uint256) {
        return requestIds.length;
    }

    /* ── minting ────────────────────────────────────────────────── */

    function mint(uint256 actorSeed, uint256 count, uint256 who) external {
        calls["mint"]++;
        uint256 left = SUPPLY - frens.totalMinted();
        if (left == 0) return;
        bool low = who % 4 == 0;
        address a;
        if (low) {
            if (pepes + 1 > 1598) return; // no pepe left to hold for it: the contract says SoldOut
            a = poor;
            count = 1;
        } else {
            a = actors[actorSeed % actors.length];
            count = bound(count, 1, left < 69 ? left : 69);
        }
        _mintFor(a, count, low);
    }

    /// @dev A mint sold straight back to the floor never profits: the quote is never below the floor it joins
    function mintThenRecycle(uint256 actorSeed) external {
        calls["mintThenRecycle"]++;
        if (frens.totalMinted() == SUPPLY) return;
        // Bootstrap has no existing floor holders. Once minted, LastFrenOut keeps at least one in the world.
        if (frens.totalMinted() == 0) return;
        address a = actors[actorSeed % actors.length];
        uint256 paid = frens.quote(1);
        uint256 id = _mintFor(a, 1, false);
        (,,,,,,, uint32 first,,) = frens.requests(id);
        vm.prank(a);
        (uint256 got6900, uint256 gotImd) = frens.recycle(first);
        ghost6900Out += got6900;
        uint256 value = got6900 * 1e18 / swapper.floorRate() + gotImd;
        assertLe(value, paid, "mint and sell straight back: never more than was paid");
    }

    function _mintFor(address a, uint256 count, bool low) internal returns (uint256 id) {
        uint24[] memory cs = new uint24[](count);
        for (uint256 i; i < count; ++i) {
            cs[i] = _fresh(low);
        }
        uint256 paid = frens.quote(count);
        if (low) {
            // exactly 1 $IMD left after paying, no IMD6900, no identity.md: tier 0
            _setImd(a, paid + 1e18);
            uint256 b = imd6900.balanceOf(a);
            if (b != 0) {
                vm.prank(a);
                imd6900.transfer(sink, b);
            }
        } else if (imd.balanceOf(a) < 1e9 * 1e18 + paid) {
            imd.mint(a, 1e9 * 1e18 + paid); // tier 3 whatever it pays
        }
        uint256 before = imd6900.balanceOf(address(frens));
        uint256 mintedBefore = frens.totalMinted();
        vm.prank(a);
        try frens.requestMint(uint8(count), paid) returns (uint256 id_) {
            id = id_;
        } catch (bytes memory err) {
            assertTrue(false, string.concat("requestMint reverted: ", vm.toString(err)));
        }
        ghost6900In += imd6900.balanceOf(address(frens)) - before;
        ghostImdUnswept = 0; // a mint sweeps whatever $IMD arrived
        requestIds.push(id);
        for (uint256 i; i < count; ++i) {
            combosOf[id].push(cs[i]);
        }
        (address minter, uint8 tier, bool lowTier,, uint8 n, uint8 revealed,, uint32 first,,) = frens.requests(id);
        assertEq(minter, a, "the request is the minter's");
        assertEq(n, count);
        assertEq(revealed, 0);
        assertEq(first, mintedBefore + 1, "its frens follow the last minted");
        assertEq(frens.totalMinted(), mintedBefore + count);
        assertEq(frens.ownerOf(first), a);
        assertEq(frens.ownerOf(first + count - 1), a);
        if (low) {
            assertEq(tier, 0);
            assertTrue(lowTier);
        } else {
            assertEq(tier, 3);
        }
    }

    /// @dev A fresh combo the request's tier may take: mumus and bobos (tier 2) for the rich until their caps, then
    ///      pepes; pepes only for the poor. All are faces 0-11, lenses 0-2, coats 0-1, no hat, no item: open to tier 0.
    function _fresh(bool low) internal returns (uint24) {
        if (!low && mumus < 312) return _of(MUMU, mumus++);
        if (!low && bobos < 312) return _of(BOBO, bobos++);
        return _of(PEPE, pepes++);
    }

    function _of(uint8 ch, uint256 i) internal pure returns (uint24) {
        return _combo(
            ch,
            uint8(i % 12),
            uint8((i / 12) % 3),
            uint8((i / 36) % 2),
            uint8((i / 72) % 6),
            0,
            uint8((i / 432) % 12),
            0
        );
    }

    function _setImd(address a, uint256 want) internal {
        uint256 have = imd.balanceOf(a);
        if (have < want) imd.mint(a, want - have);
        if (have > want) {
            vm.prank(a);
            imd.transfer(sink, have - want);
        }
    }

    /* ── reveals ────────────────────────────────────────────────── */

    function reveal(uint256 reqSeed, uint256 upToSeed) external {
        calls["reveal"]++;
        (bool found, uint256 id) = _pending(reqSeed);
        if (!found) return;
        (,, bool lowTier,, uint8 count, uint8 revealed,, uint32 first,,) = frens.requests(id);
        uint256 upTo = bound(upToSeed, revealed + 1, count);
        uint24[] memory cs = combosOf[id];
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(relayerKey, frens.voucherDigest(id, cs, "job", keccak256("out"), deadline));
        for (uint256 i = revealed; i < upTo; ++i) {
            assertFalse(frens.taken(cs[i]), "a fresh combo");
        }
        uint256 openBefore = frens.openLowTier();
        try frens.reveal(id, cs, "job", keccak256("out"), deadline, abi.encodePacked(r, s, v), upTo) {}
        catch (bytes memory err) {
            assertTrue(false, string.concat("reveal reverted: ", vm.toString(err)));
        }
        for (uint256 i = revealed; i < upTo; ++i) {
            assertTrue(frens.taken(cs[i]), "taken now");
            assertEq(frens.comboOf(first + i), cs[i]);
            assertTrue(frens.seedOf(first + i) != 0, "revealed: a seed");
        }
        ghostRevealed += upTo - revealed;
        (,,,,, uint8 revealedNow, uint8 jobs,,,) = frens.requests(id);
        assertEq(revealedNow, upTo);
        if (upTo == count) assertEq(jobs, 0, "a revealed request has no job waiting");
        assertEq(frens.openLowTier(), lowTier ? openBefore - (upTo - revealed) : openBefore, "the pepes held");
    }

    /// @dev A request not fully revealed, starting from the seed; none if all are
    function _pending(uint256 seed) internal view returns (bool, uint256) {
        uint256 n = requestIds.length;
        if (n == 0) return (false, 0);
        uint256 start = seed % n;
        for (uint256 k; k < n; ++k) {
            uint256 id = requestIds[(start + k) % n];
            (,,,, uint8 count, uint8 revealed,,,,) = frens.requests(id);
            if (revealed < count) return (true, id);
        }
        return (false, 0);
    }

    /* ── the floor ──────────────────────────────────────────────── */

    function recycle(uint256 tokenSeed) external {
        calls["recycle"]++;
        uint256 total = frens.totalMinted();
        if (total == 0) return;
        uint256 id = bound(tokenSeed, 1, total);
        address owner = frens.ownerOf(id);
        if (owner == address(frens)) return;
        if (total - frens.inTreasury() == 1) {
            bytes32 beforeState = _floorSnapshot(owner, id);
            vm.prank(owner);
            vm.expectRevert(IMD6900Frens.LastFrenOut.selector);
            frens.recycle(id);
            assertEq(_floorSnapshot(owner, id), beforeState, "last-fren refusal rolls back the sweep and payout");
            calls["lastRecycleRejected"]++;
            return;
        }
        // a sale sweeps the $IMD that arrived first, then pays its share of all of it
        (uint256 p6900, uint256 pImd) = _floorParts();
        uint256 b6900 = imd6900.balanceOf(owner);
        uint256 bImd = imd.balanceOf(owner);
        vm.prank(owner);
        try frens.recycle(id) returns (uint256 paid, uint256 imdPaid) {
            assertEq(paid, p6900, "recycle pays the floor");
            assertEq(imdPaid, pImd, "and the waiting $IMD's share");
            assertEq(imd6900.balanceOf(owner) - b6900, paid);
            assertEq(imd.balanceOf(owner) - bImd, imdPaid);
            ghost6900Out += paid;
            ghostImdUnswept = 0; // swept
        } catch (bytes memory err) {
            assertTrue(false, string.concat("recycle reverted: ", vm.toString(err)));
        }
        assertEq(frens.ownerOf(id), address(frens), "in the treasury");
    }

    function buyTreasury(uint256 actorSeed, uint256 tokenSeed) external {
        calls["buyTreasury"]++;
        uint256 total = frens.totalMinted();
        if (total == 0) return;
        uint256 id = bound(tokenSeed, 1, total);
        if (frens.ownerOf(id) != address(frens)) return;
        address a = actors[actorSeed % actors.length];
        // twice the floor, swept first, and twice the share of the ETH waiting to be bought in, in $IMD
        (uint256 p6900, uint256 pImd) = _floorParts();
        pImd += IFrenSwapper(frens.swapper()).floorValue(0, address(frens)) / _out();
        (p6900, pImd) = (2 * p6900, 2 * pImd);
        if (p6900 != 0) imd6900.mint(a, p6900);
        if (pImd != 0) imd.mint(a, pImd);
        // one wei short on either part: refused
        if (p6900 != 0) {
            bytes32 beforeState = _floorSnapshot(a, id);
            vm.prank(a);
            vm.expectRevert(IMD6900Frens.Cap.selector);
            frens.buyTreasury(id, p6900 - 1, pImd);
            assertEq(_floorSnapshot(a, id), beforeState, "short reserve cap rolls back the sweep and payment");
            calls["reserveCapRejected"]++;
        }
        if (pImd != 0) {
            bytes32 beforeState = _floorSnapshot(a, id);
            vm.prank(a);
            vm.expectRevert(IMD6900Frens.Cap.selector);
            frens.buyTreasury(id, p6900, pImd - 1);
            assertEq(_floorSnapshot(a, id), beforeState, "short IMD cap rolls back the sweep and payment");
            calls["imdCapRejected"]++;
        }
        vm.prank(a);
        try frens.buyTreasury(id, p6900, pImd) returns (uint256 paid, uint256 imdPaid) {
            assertEq(paid, p6900, "twice the floor");
            assertEq(imdPaid, pImd);
            ghost6900In += paid;
            ghostImdUnswept = 0; // swept
        } catch (bytes memory err) {
            assertTrue(false, string.concat("buyTreasury reverted: ", vm.toString(err)));
        }
        assertEq(frens.ownerOf(id), a);
    }

    function _out() internal view returns (uint256 out) {
        out = frens.totalMinted() - frens.inTreasury();
        if (out == 0) out = 1;
    }

    function _floorSnapshot(address actor, uint256 id) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                frens.ownerOf(id),
                frens.inTreasury(),
                frens.totalMinted(),
                frens.reserve(),
                frens.floorImd(),
                frens.jobBudget(),
                imd.balanceOf(address(frens)),
                imd6900.balanceOf(address(frens)),
                imd.balanceOf(actor),
                imd6900.balanceOf(actor),
                address(frens).balance
            )
        );
    }

    /// @dev floorPerFren once the unswept $IMD is swept in, as recycle and buyTreasury do first
    function _floorParts() internal view returns (uint256 p6900, uint256 pImd) {
        (p6900, pImd) = (frens.reserve() / _out(), (frens.floorImd() + ghostImdUnswept) / _out());
    }

    function transfer(uint256 toSeed, uint256 tokenSeed) external {
        calls["transfer"]++;
        uint256 total = frens.totalMinted();
        if (total == 0) return;
        uint256 id = bound(tokenSeed, 1, total);
        address owner = frens.ownerOf(id);
        if (owner == address(frens)) return;
        uint256 recipient = toSeed % (actors.length + 2);
        address to =
            recipient == actors.length + 1 ? address(frens) : recipient == actors.length ? poor : actors[recipient];
        if (to == address(frens) && total - frens.inTreasury() == 1) {
            bytes32 beforeState = _floorSnapshot(owner, id);
            vm.prank(owner);
            vm.expectRevert(IMD6900Frens.LastFrenOut.selector);
            frens.transferFrom(owner, to, id);
            assertEq(_floorSnapshot(owner, id), beforeState, "direct transfer cannot empty the world");
            calls["lastTransferRejected"]++;
            return;
        }
        vm.prank(owner);
        try frens.transferFrom(owner, to, id) {}
        catch (bytes memory err) {
            assertTrue(false, string.concat("transferFrom reverted: ", vm.toString(err)));
        }
        assertEq(frens.ownerOf(id), to);
    }

    function buyFloor(uint256 blocks) external {
        calls["buyFloor"]++;
        vm.roll(block.number + bound(blocks, 0, 2));
        uint256 waiting = frens.floorImd() + ghostImdUnswept;
        uint256 imdIn = waiting < frens.maxImdPerBuy() ? waiting : frens.maxImdPerBuy();
        bool buys = imdIn != 0 && block.number >= frens.lastFloorBuyBlock() + frens.buyDelayBlocks();
        uint256 before = imd6900.balanceOf(address(frens));
        uint256 reserveBefore = frens.reserve();
        if (!buys) {
            try frens.buyFloor(0) {
                assertTrue(false, "a floor buy with nothing to buy, or too soon, went through");
            } catch (bytes memory err) {
                assertEq(bytes4(err), IMD6900Frens.Cap.selector, "refused as Cap");
            }
            return;
        }
        try frens.buyFloor(0) {}
        catch (bytes memory err) {
            assertTrue(false, string.concat("buyFloor reverted: ", vm.toString(err)));
        }
        uint256 got = imd6900.balanceOf(address(frens)) - before;
        assertGt(got, 0, "a buy buys");
        assertEq(frens.reserve(), reserveBefore + got, "all of it into the reserve");
        assertEq(frens.floorImd(), waiting - imdIn, "the buy's $IMD left the floor");
        ghost6900In += got;
        ghostImdUnswept = 0;
        ghostFloorBuys++;
    }

    /// @dev Fee ETH arrives (royalties, the pool's share) and is bought into the reserve
    function feeEth(uint256 eth, uint256 blocks) external {
        calls["feeEth"]++;
        eth = bound(eth, 1, 0.25 ether);
        vm.deal(address(this), eth);
        (bool ok,) = address(frens).call{value: eth}("");
        assertTrue(ok, "the contract takes ETH");
        ghostEthIn += eth;
        vm.roll(block.number + bound(blocks, 0, 2));
        bool buys = block.number >= frens.lastEthBuyBlock() + frens.buyDelayBlocks() && eth <= frens.maxEthPerBuy();
        uint256 before = imd6900.balanceOf(address(frens));
        if (!buys) {
            bytes4 reason = block.number < frens.lastEthBuyBlock() + frens.buyDelayBlocks()
                ? IMD6900Frens.TooSoon.selector
                : IMD6900Frens.Cap.selector;
            try frens.buyFloorWithEth(eth, 0) {
                assertTrue(false, "an ETH buy too soon or over the cap went through");
            } catch (bytes memory err) {
                assertEq(err, abi.encodeWithSelector(reason), "ETH buy rejected for the expected reason");
            }
            return;
        }
        try frens.buyFloorWithEth(eth, 0) {}
        catch (bytes memory err) {
            assertTrue(false, string.concat("buyFloorWithEth reverted: ", vm.toString(err)));
        }
        uint256 got = imd6900.balanceOf(address(frens)) - before;
        assertGt(got, 0);
        ghost6900In += got;
        ghostEthSpent += eth;
    }

    function donate6900(uint256 amount) external {
        calls["donate6900"]++;
        amount = bound(amount, 1, 1e24);
        imd6900.mint(address(frens), amount);
        ghost6900Donated += amount;
    }

    function donateImd(uint256 amount) external {
        calls["donateImd"]++;
        amount = bound(amount, 1, 1e21);
        imd.mint(address(frens), amount);
        ghostImdUnswept += amount;
    }

    /* ── jobs ───────────────────────────────────────────────────── */

    /// @dev The keeper approves a request's next job payment; IMD may then take it (settle) through Permit2
    function approveJob(uint256 reqSeed, uint256 ttl, bool settle) external {
        calls["approveJob"]++;
        (bool found, uint256 id) = _pending(reqSeed);
        if (!found) return;
        (,,, bool jobApproved,,, uint8 jobs,, uint40 jobDeadline, uint256 jobNonce) = frens.requests(id);
        bool approvedUnspent =
            jobApproved && permit2.nonceBitmap(address(frens), jobNonce >> 8) & (1 << (jobNonce & 0xff)) == 0;
        bool ok;
        if (approvedUnspent && block.timestamp <= jobDeadline) ok = false; // the last payment can still be taken
        else ok = jobs + (approvedUnspent ? 1 : 0) != 0;
        uint256 deadline = block.timestamp + bound(ttl, 1, 1 hours);
        IMD6900Frens.Quote memory q =
            IMD6900Frens.Quote("r", bytes32("s"), "q", bytes32("qh"), bytes32("ph"), "job.open", deadline);
        uint256 nonce = nonces++;
        uint256 budgetBefore = frens.jobBudget();
        uint256 allowanceBefore = imd.allowance(address(frens), address(permit2));
        vm.prank(keeper);
        try frens.approveJob(id, nonce, deadline, q) returns (bytes32 permitDigest, bytes32 quoteDigest) {
            assertTrue(ok, "approved a job it should have refused");
            assertEq(frens.isValidSignature(permitDigest, ""), bytes4(0x1626ba7e), "the contract signs the payment");
            assertEq(frens.isValidSignature(quoteDigest, ""), bytes4(0x1626ba7e));
            assertEq(
                frens.jobBudget(), budgetBefore + (approvedUnspent ? JOB : 0) - JOB, "one job's money out of the budget"
            );
            assertEq(
                imd.allowance(address(frens), address(permit2)), allowanceBefore + JOB - (approvedUnspent ? JOB : 0)
            );
            if (settle) {
                vm.prank(address(permit2));
                imd.transferFrom(address(frens), payTo, JOB);
                permit2.spend(address(frens), nonce);
            }
        } catch (bytes memory err) {
            assertFalse(ok, string.concat("approveJob reverted: ", vm.toString(err)));
            assertTrue(err.length == 4 && bytes4(err) == IMD6900Frens.BadJob.selector, "refused as BadJob");
        }
    }

    function retryJob(uint256 reqSeed, uint256 actorSeed) external {
        calls["retryJob"]++;
        (bool found, uint256 id) = _pending(reqSeed);
        if (!found) return;
        (,,,,,, uint8 jobs,,,) = frens.requests(id);
        address a = actors[actorSeed % actors.length];
        imd.mint(a, JOB);
        uint256 budgetBefore = frens.jobBudget();
        vm.prank(a);
        try frens.retryJob(id) {
            assertEq(jobs, 0, "a retry only when no job is paid for");
            assertEq(frens.jobBudget(), budgetBefore + JOB);
        } catch (bytes memory err) {
            assertTrue(jobs != 0, string.concat("retryJob reverted: ", vm.toString(err)));
            assertEq(err, abi.encodeWithSelector(IMD6900Frens.BadJob.selector), "retry refused as BadJob");
        }
    }

    function warp(uint256 secs) external {
        calls["warp"]++;
        vm.warp(block.timestamp + bound(secs, 1, 2 hours));
    }

    /* ── the governor and the pool ──────────────────────────────── */

    function setParams(uint256 delay, uint256 imdCap, uint256 ethCap) external {
        calls["setParams"]++;
        vm.prank(OWNER);
        frens.setParams(bound(delay, 0, 3), bound(imdCap, 0, 200e18), bound(ethCap, 0, 0.5 ether));
    }

    function setRate(uint256 rate) external {
        calls["setRate"]++;
        swapper.setRate(bound(rate, 1, 1e6));
    }
}

/// @notice Invariants of the collection the launch places at 0x6900… (its exact creation code and price table, the
///         team wallet's setup, $IMD / IMD6900 / Permit2 / the swapper as local stand-ins): what it holds is what
///         its books say, the reserve only moves through the floor, frens are conserved, the trait caps and the pepes
///         held for low tiers hold, and the job money is whole jobs.
contract FrensPlacedInvariantsTest is Test, FrensRules {
    bytes constant CREATE2_DEPLOYER_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    uint256 constant RELAYER_KEY = 0xA11CE;

    IMD6900Frens frens;
    MockToken imd;
    NoZeroToken imd6900;
    MockPermit2 permit2;
    MockSwapper swapper;
    PlacedFrensHandler handler;

    function setUp() public {
        vm.etch(FrensPlan.CREATE2_DEPLOYER, CREATE2_DEPLOYER_CODE);
        vm.etch(FrensPlan.IMD, address(new PlainImd()).code);
        vm.etch(FrensPlan.IMD6900, address(new NoZeroToken()).code);
        vm.etch(FrensPlan.IDENTITY, address(new MockToken("identity")).code);
        vm.etch(FrensPlan.PERMIT2, address(new MockPermit2()).code);
        imd = MockToken(FrensPlan.IMD);
        imd6900 = NoZeroToken(FrensPlan.IMD6900);
        permit2 = MockPermit2(FrensPlan.PERMIT2);
        PlaceFrens pf = new PlaceFrens();
        frens = IMD6900Frens(payable(pf.frens()));
        assertEq(address(frens), FrensPlan.FRENS_AT, "the placed collection");
        swapper = new MockSwapper(imd6900, imd);
        address keeper = makeAddr("keeper");
        address payTo = makeAddr("IMD's payee");
        vm.startPrank(FrensPlan.OWNER);
        _rules(frens, [uint16(1598), 312, 312]);
        frens.sealTraits();
        frens.setModules(address(swapper), address(0));
        frens.setRoles(keeper, vm.addr(RELAYER_KEY), payTo);
        frens.setMintOpen(true);
        vm.stopPrank();
        handler = new PlacedFrensHandler(frens, swapper, RELAYER_KEY, keeper, payTo);
        targetContract(address(handler));
        bytes4[] memory s = new bytes4[](16);
        s[0] = handler.mint.selector;
        s[1] = handler.mintThenRecycle.selector;
        s[2] = handler.reveal.selector;
        s[3] = handler.recycle.selector;
        s[4] = handler.buyTreasury.selector;
        s[5] = handler.transfer.selector;
        s[6] = handler.buyFloor.selector;
        s[7] = handler.feeEth.selector;
        s[8] = handler.donate6900.selector;
        s[9] = handler.donateImd.selector;
        s[10] = handler.approveJob.selector;
        s[11] = handler.retryJob.selector;
        s[12] = handler.warp.selector;
        s[13] = handler.setParams.selector;
        s[14] = handler.setRate.selector;
        s[15] = handler.mint.selector; // mints twice as often: everything else needs frens
        targetSelector(FuzzSelector({addr: address(handler), selectors: s}));
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    /// @dev Invariant R, and nothing more: the IMD6900 here is the reserve plus what was sent outside the floor
    function invariant_ReserveIsExactlyWhatIsHere() public view {
        assertEq(imd6900.balanceOf(address(frens)), frens.reserve() + handler.ghost6900Donated(), "the reserve is here");
        assertEq(
            frens.reserve(), handler.ghost6900In() - handler.ghost6900Out(), "the reserve moves only through the floor"
        );
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    /// @dev The $IMD here is the floor's, the jobs', the approved payments', and what arrived since the last buy
    function invariant_ImdIsTheBooks() public view {
        uint256 books = frens.floorImd() + frens.jobBudget() + imd.allowance(address(frens), address(permit2));
        assertEq(imd.balanceOf(address(frens)), books + handler.ghostImdUnswept(), "the books");
        assertEq(address(frens).balance, handler.ghostEthIn() - handler.ghostEthSpent(), "the ETH");
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    /// @dev Every fren minted is a wallet's or the treasury's, never more than 2222, and the requests add up to them
    function invariant_FrensAreConserved() public view {
        uint256 held = frens.inTreasury() + frens.balanceOf(handler.poor());
        for (uint256 i; i < handler.actorCount(); ++i) {
            held += frens.balanceOf(handler.actors(i));
        }
        assertEq(held, frens.totalMinted(), "every fren is somewhere");
        assertLe(frens.totalMinted(), 2222);
        if (frens.totalMinted() != 0) assertLt(frens.inTreasury(), frens.totalMinted(), "the last fren stays out");
        uint256 n = frens.nextRequestId() - 1;
        assertEq(n, handler.requestCount(), "one request a mint");
        uint256 counted;
        uint256 open;
        uint256 jobs;
        uint256 approved;
        for (uint256 id = 1; id <= n; ++id) {
            (,, bool lowTier, bool jobApproved, uint8 count, uint8 revealed, uint8 js,,, uint256 nonce) =
                frens.requests(id);
            counted += count;
            if (lowTier) open += count - revealed;
            jobs += js;
            if (jobApproved && permit2.nonceBitmap(address(frens), nonce >> 8) & (1 << (nonce & 0xff)) == 0) {
                ++approved;
            }
        }
        assertEq(counted, frens.totalMinted(), "the requests' frens are the frens");
        assertEq(open, frens.openLowTier(), "the pepes held for low tiers are their unrevealed frens");
        assertEq(frens.jobBudget(), jobs * 0.5e18, "the job budget is the jobs paid for and not approved");
        assertEq(
            imd.allowance(address(frens), address(permit2)),
            approved * 0.5e18,
            "Permit2 may take exactly the approved payments"
        );
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    /// @dev No trait value past its cap, every revealed fren counted once in every trait, and never more pepes
    ///      revealed and held than there are
    function invariant_CapsHold() public view {
        uint8[8] memory values = [3, 13, 4, 3, 6, 3, 12, 16];
        for (uint8 t; t < 8; ++t) {
            uint256 sum;
            for (uint8 v; v < values[t]; ++v) {
                IMD6900Frens.Rule memory r = frens.ruleOf(t, v);
                assertLe(r.minted, r.cap, "a cap");
                sum += r.minted;
            }
            assertEq(sum, handler.ghostRevealed(), "each revealed fren has one value of every trait");
        }
        assertLe(frens.ruleOf(0, 0).minted + frens.openLowTier(), 1598, "pepes revealed and held never exceed them");
        uint256 revealed;
        for (uint256 id = 1; id <= frens.totalMinted(); ++id) {
            if (frens.seedOf(id) != 0) ++revealed;
        }
        assertEq(revealed, handler.ghostRevealed(), "a seed exactly for the revealed");
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    /// @dev The floor is a share: nothing the treasury holds is counted out in the world
    function invariant_FloorIsAShareOfTheWorld() public view {
        (uint256 p6900, uint256 pImd) = frens.floorPerFren();
        uint256 out = frens.totalMinted() - frens.inTreasury();
        if (out == 0) out = 1;
        assertLe(p6900 * out, frens.reserve(), "no more than the reserve");
        assertLe(pImd * out, frens.floorImd());
        assertGt((p6900 + 1) * out, frens.reserve(), "no less than its share");
        assertGt((pImd + 1) * out, frens.floorImd());
        assertEq(frens.owner(), FrensPlan.OWNER, "the team wallet's");
        assertEq(frens.governor(), FrensPlan.OWNER);
    }

    function test_HandlerKeepsLastFrenOutAndRejectionsAreAtomic() public {
        handler.mint(0, 2, 1);
        handler.recycle(1);
        handler.donateImd(1e18);
        handler.recycle(2);
        handler.transfer(handler.actorCount() + 1, 2);
        assertEq(handler.calls("lastRecycleRejected"), 1);
        assertEq(handler.calls("lastTransferRejected"), 1);
        assertEq(handler.ghostImdUnswept(), 1e18);
        assertEq(frens.inTreasury(), 1);
        assertEq(frens.ownerOf(2), handler.actors(0));
        _assertAllInvariants();
    }

    function test_HandlerChecksBothTreasuryCapsAfterDonation() public {
        handler.mint(0, 2, 1);
        handler.recycle(1);
        handler.donateImd(1e18);
        handler.buyTreasury(1, 1);
        assertEq(handler.calls("reserveCapRejected"), 1);
        assertEq(handler.calls("imdCapRejected"), 1);
        assertEq(frens.ownerOf(1), handler.actors(1));
        assertEq(handler.ghostImdUnswept(), 0);
        _assertAllInvariants();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_SpentNonceRejectsOnlyItsOwnBit(uint256 nonce) public {
        _checkSpentNonce(nonce);
    }

    function test_SpentNonceBitmapBoundaries() public {
        _checkSpentNonce(0);
        _checkSpentNonce(255);
        _checkSpentNonce(256);
        _checkSpentNonce(type(uint256).max);
        _assertAllInvariants();
    }

    function _checkSpentNonce(uint256 nonce) internal {
        handler.mint(0, 1, 1);
        uint256 id = frens.nextRequestId() - 1;
        uint256 deadline = block.timestamp + 600;
        IMD6900Frens.Quote memory q =
            IMD6900Frens.Quote("r", bytes32("s"), "q", bytes32("qh"), bytes32("ph"), "job.open", deadline);
        permit2.spend(address(frens), nonce);
        uint256 budgetBefore = frens.jobBudget();
        uint256 allowanceBefore = imd.allowance(address(frens), address(permit2));
        uint256 balanceBefore = imd.balanceOf(address(frens));
        vm.prank(handler.keeper());
        vm.expectRevert(IMD6900Frens.BadJob.selector);
        frens.approveJob(id, nonce, deadline, q);
        assertEq(frens.jobBudget(), budgetBefore, "a spent nonce cannot consume the job budget");
        assertEq(imd.allowance(address(frens), address(permit2)), allowanceBefore);
        assertEq(imd.balanceOf(address(frens)), balanceBefore);
        (,,, bool approved,,, uint8 jobs,,,) = frens.requests(id);
        assertFalse(approved);
        assertEq(jobs, 1);

        // A different bit in the same bitmap word is still usable, including at the uint256 boundary.
        vm.prank(handler.keeper());
        (bytes32 digest,) = frens.approveJob(id, nonce ^ 1, deadline, q);
        assertEq(frens.isValidSignature(digest, ""), bytes4(0x1626ba7e));
        assertEq(frens.jobBudget(), budgetBefore - frens.JOB_PRICE());
        assertEq(imd.allowance(address(frens), address(permit2)), allowanceBefore + frens.JOB_PRICE());
    }

    /// @dev Exercise every selected action with live state, including formerly skipped unswept-IMD round trips.
    function test_HandlerSequenceExercisesPaymentsRevealsAndFailures() public {
        handler.mint(0, 3, 1);
        handler.mint(0, 1, 0);
        handler.transfer(1, 1);
        handler.transfer(1, 1); // self-transfer
        handler.donate6900(1e18);
        handler.donateImd(1e18);
        handler.mintThenRecycle(2);
        assertEq(frens.ownerOf(5), address(frens));
        assertEq(handler.ghostImdUnswept(), 0);
        handler.buyTreasury(3, 5);
        handler.setParams(0, 50e18, 0.25 ether);
        handler.setRate(70_000);
        handler.buyFloor(1);
        handler.feeEth(1e15, 1);
        handler.reveal(0, 1);
        handler.approveJob(0, 600, false);
        handler.approveJob(0, 600, false); // live unspent approval refuses a replacement
        handler.warp(601);
        handler.approveJob(0, 600, true); // expired approval reclaimed, replacement settled
        handler.retryJob(0, 1);
        handler.retryJob(0, 1); // cannot fund the same retry twice
        handler.reveal(0, 3);
        handler.setParams(3, 0, 0);
        handler.feeEth(1, 0); // delay checked before the zero cap
        handler.feeEth(1, 2);
        handler.feeEth(1, 2); // cap checked once the delay has elapsed
        handler.buyFloor(0);
        assertEq(handler.requestCount(), 3);
        assertEq(handler.ghostRevealed(), 3);
        assertGt(handler.ghostFloorBuys(), 0);
        assertGt(handler.ghostEthSpent(), 0);
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal view {
        invariant_ReserveIsExactlyWhatIsHere();
        invariant_ImdIsTheBooks();
        invariant_FrensAreConserved();
        invariant_CapsHold();
        invariant_FloorIsAShareOfTheWorld();
    }
}
