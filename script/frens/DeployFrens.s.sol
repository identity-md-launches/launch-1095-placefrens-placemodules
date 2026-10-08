// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IMD6900Frens} from "../../src/frens/IMD6900Frens.sol";
import {FrenSwapper} from "../../src/frens/FrenSwapper.sol";
import {FrenMinter} from "../../src/frens/FrenMinter.sol";
import {FrenWorkerGate} from "../../src/frens/FrenWorkerGate.sol";
import {FrenPrices} from "../../src/frens/FrenPrices.sol";
import {FrensPlan} from "../../src/FrensPlan.sol";

interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IPlacedModules {
    function frens() external view returns (address);
    function swapper() external view returns (address);
    function minter() external view returns (address);
    function gate() external view returns (address);
}

interface IStrategyMin {
    function isDistributor(address) external view returns (bool);
}

interface IPairExemption {
    function feeExempt(address) external view returns (bool);
}

/// @notice The frens after the IMD swarm's two launches (the collection: src/FrensPlacement.sol, at FrensPlan's
///         addresses; the art: WorkerArt1, WorkerArt2 and WorkerFrensRenderer): the team wallet (owner and governor)
///         wires them, points them at the art launch's renderer, mints the curve's first frens to IMD6900 and hands the
///         governor to the timelock. Every call is the team wallet's. The other tests deploy the same contracts with
///         plain `new` ({deploy}).
///   MODULES=<the collection launch's PlaceModules> RENDERER=<the art launch's WorkerFrensRenderer> \
///     forge script script/frens/DeployFrens.s.sol --sig "setup()" --rpc-url … --account imdstr-deployer --broadcast
contract DeployFrens is Script {
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant IMD6900 = 0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F;
    address public constant IDENTITY = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant X402_PROXY = 0x402085c248EeA27D92E8b30b2C58ed07f9E20001;
    address public constant IMD_PAY_TO = 0xC94400e90bB652AFA02740bFf50824E14069c133; // job payee: the relayer's payer
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant PAIR_HOOK = 0x667f4621030aCfAfb1bD0B64d33610A8567f2A44; // IMD6900/$IMD
    address public constant POOL4_HOOK = 0xc6C965Bd164c483e87d0B550671798e9A3602840; // IMD's ETH/$IMD
    address public constant TIMELOCK = 0xBd3ed9F4AbD9946cA6F59C8F13A3EbebDE1EA29D;
    address public constant DEPLOYER = 0x35dA9C0303507ddf708E87F2568EdDf12c47a059; // the team wallet: owner and governor
    address public constant KEEPER = 0x75521bC4b21CAFD5bbc008A76D0988f777BD5888; // the frens relayer's keeper (Railway)
    address public constant RELAYER = 0x3c038c9D0ab5532b5cae78dABeda916e34af3D5E; // signs the reveal vouchers

    struct Deployed {
        IMD6900Frens frens;
        FrenSwapper swapper;
        address prices;
        FrenMinter minter;
        FrenWorkerGate gate;
    }

    /// @notice After the swarm's launches, from the team wallet (the frens' owner and governor): the art launch's
    ///         renderer (RENDERER in the env), the swapper and the workers' window, the launch's trait rules, sealed. Reads
    ///         where the collection launch put them (MODULES in the env: its PlaceModules). Until the Ethereum timelock's batch
    ///         makes the frens an IMD6900 distributor, the floor's buys are paused (the floor waits in $IMD): IMD6900
    ///         bought before that could never be paid out, and every recycle and treasury buy would fail on it. {resume}
    ///         turns the buys back on once the batch has landed.
    function setup() external {
        (address frens, address swapper,, address gate) = placed();
        address renderer = _renderer();
        require(renderer.code.length != 0, "no renderer at RENDERER");
        IMD6900Frens f = IMD6900Frens(payable(frens));
        _checkSwapper(swapper);
        bool paused = f.totalMinted() == 0 || !IStrategyMin(IMD6900).isDistributor(frens);
        vm.startBroadcast(DEPLOYER);
        f.setRenderer(renderer);
        if (paused) f.setParams(f.buyDelayBlocks(), 0, 0);
        f.setModules(swapper, gate);
        launchRules(f);
        f.sealTraits();
        vm.stopBroadcast();
        console2.log("frens", frens, "set up, sealed, drawn by", renderer);
        if (paused) console2.log("floor buys paused: firstFrens(), then the timelock batch, then resume()");
    }

    /// @notice Once the timelock's batch has made the frens an IMD6900 distributor: the floor's buys back on, at the
    ///         collection's defaults (50 $IMD and 0.25 ETH a buy, one buy a block)
    function resume() external {
        (address frens, address swapper,, address gate) = placed();
        require(IStrategyMin(IMD6900).isDistributor(frens), "not an IMD6900 distributor yet: the batch hasn't landed");
        IMD6900Frens f = IMD6900Frens(payable(frens));
        _requireFirstFrens(f);
        require(f.swapper() == swapper && f.workerGate() == gate, "modules differ from the launch");
        require(IPairExemption(PAIR_HOOK).feeExempt(swapper), "actual swapper is not fee-exempt");
        _checkSwapper(swapper);
        vm.broadcast(DEPLOYER);
        f.setParams(1, 50e18, 0.25 ether);
        console2.log("frens", frens, "floor buys resumed");
    }

    /// @notice Open the workers' and WL's window only after the strategy holds the first frens.
    function open() external {
        (address frens, address swapper,, address gate) = placed();
        IMD6900Frens f = IMD6900Frens(payable(frens));
        _requireFirstFrens(f);
        require(f.traitsSealed() && f.renderer().code.length != 0, "run setup first");
        require(f.swapper() == swapper && f.workerGate() == gate, "modules differ from the launch");
        _checkSwapper(swapper);
        vm.broadcast(DEPLOYER);
        f.setMintOpen(true);
    }

    function _requireFirstFrens(IMD6900Frens f) internal view {
        require(f.totalMinted() > f.inTreasury(), "mint the strategy's first frens before opening or resuming");
    }

    /// @dev A later-block activation check; this does not prove the launch block's price was fair.
    function _checkSwapper(address swapper) internal view {
        if (POOL_MANAGER.code.length == 0) return;
        FrenSwapper s = FrenSwapper(payable(swapper));
        uint256 avg = s.rateAverage();
        uint256 spot = s.spotRate();
        require(avg != 0 && spot != 0 && avg * 2 >= spot && avg <= spot * 2, "swapper average outside spot band");
    }

    /// @notice Where src/FrensPlacement.sol put them: read from the launch's PlaceModules (MODULES in the env), which
    ///         knows its swapper even where it had to create its own instead of the one at FrensPlan.SWAPPER_AT.
    ///         MODULES is required. Individual address overrides cannot replace the launch's reported contracts.
    function placed() public view returns (address frens, address swapper, address minter, address gate) {
        address modules = _modules();
        require(modules.code.length != 0, "MODULES must be the collection launch's PlaceModules");
        IPlacedModules pm = IPlacedModules(modules);
        (frens, swapper, minter, gate) = (pm.frens(), pm.swapper(), pm.minter(), pm.gate());
        require(
            frens.code.length != 0 && swapper.code.length != 0 && minter.code.length != 0 && gate.code.length != 0,
            "not placed"
        );
        if (block.chainid == 1) require(frens == FrensPlan.FRENS_AT, "wrong Ethereum collection");
        require(
            FrenSwapper(payable(swapper)).frens() == frens && address(FrenMinter(payable(minter)).frens()) == frens
                && FrenWorkerGate(gate).frens() == frens,
            "modules belong to another collection"
        );
    }

    function _modules() internal view virtual returns (address) {
        return vm.envOr("MODULES", address(0));
    }

    function _renderer() internal view virtual returns (address) {
        return vm.envAddress("RENDERER");
    }

    /// @notice The curve's first `count` frens to IMD6900 (its seats hold identity.md NFTs), 69 a request, paid with
    ///         the ETH sent: FrenMinter buys exactly their price in $IMD on POOL4 first. Before the opening only.
    function firstFrens(IMD6900Frens frens, FrenMinter minter, uint256 count, uint256 ethIn) external {
        require(!frens.mintOpen(), "before the opening only");
        require(count != 0, "no first frens requested");
        require(address(minter.frens()) == address(frens), "minter belongs to another collection");
        if (frens.totalMinted() == 0) {
            require(frens.maxImdPerBuy() == 0 && frens.maxEthPerBuy() == 0, "run setup to pause floor buys first");
        }
        uint256 cost;
        for (uint256 n = frens.totalMinted(); n < frens.totalMinted() + count; ++n) {
            cost += frens.priceOf(n);
        }
        cost += cost / 100; // the floor rule can lift a later request a little above the curve
        vm.startBroadcast(DEPLOYER);
        minter.buyImd{value: ethIn}(cost);
        IERC20Min(IMD).approve(address(frens), cost);
        for (uint256 left = count; left > 0;) {
            uint8 n = uint8(left > 69 ? 69 : left);
            frens.requestMintFor{gas: 800_000 + 35_000 * uint256(n)}(IMD6900, n, type(uint256).max);
            left -= n;
        }
        IERC20Min(IMD).approve(address(frens), 0);
        vm.stopBroadcast();
        console2.log("frens minted to the strategy", count, "total minted", frens.totalMinted());
    }

    /// @notice The mint's and the floor's settings to the Ethereum timelock (governor); the owner stays the team wallet
    function handover(IMD6900Frens frens) external {
        vm.broadcast(DEPLOYER);
        frens.setGovernor(TIMELOCK);
        console2.log("governor", frens.governor(), "owner (the collection)", frens.owner());
    }

    /// @dev Every contract with plain deploys, from the caller (the tests), set up and sealed the same way
    function deploy(address owner, address keeper, address relayer) public returns (Deployed memory d) {
        d.prices = address(new FrenPrices());
        d.frens =
            new IMD6900Frens(owner, IMD, IMD6900, IDENTITY, PERMIT2, X402_PROXY, IMD_PAY_TO, keeper, relayer, d.prices);
        d.swapper = new FrenSwapper(POOL_MANAGER, IMD, IMD6900, address(d.frens), PAIR_HOOK, POOL4_HOOK);
        d.minter = new FrenMinter(POOL_MANAGER, address(d.frens), POOL4_HOOK, PAIR_HOOK);
        d.gate = new FrenWorkerGate(owner, address(d.frens), IDENTITY, IMD6900);
        d.frens.setModules(address(d.swapper), address(d.gate));
        launchRules(d.frens);
        d.frens.sealTraits();
    }

    /// @notice The launch rules (the relayer's tools/fren-job.mjs launchRules() mirrors them; test/frens/FrensRules.sol):
    ///  - characters 1598 cyborg pepe / 312 mumu / 312 bobo, mumu and bobo from tier 2;
    ///  - laser eyes (56) tier 3; gold lens (222), gold coat (103) tier 1; hats (266 each) tier 1;
    ///  - items 140 each, six common ones open to all, the rest tier 1, the two lightsabers (56 each) tier 3;
    ///  - a gold-coat mumu or bobo tier 3.
    function launchRules(IMD6900Frens f) public {
        (uint16[] memory c, uint8[] memory t) = _fill(3, 0, 0);
        (c[0], c[1], c[2], t[1], t[2]) = (1598, 312, 312, 2, 2);
        f.setTraitRules(0, c, t);
        (c, t) = _fill(13, 2222, 0);
        (c[12], t[12]) = (56, 3);
        f.setTraitRules(1, c, t);
        (c, t) = _fill(4, 2222, 0);
        (c[3], t[3]) = (222, 1);
        f.setTraitRules(2, c, t);
        (c, t) = _fill(3, 2222, 0);
        (c[2], t[2]) = (103, 1);
        f.setTraitRules(3, c, t);
        (c, t) = _fill(6, 2222, 0);
        f.setTraitRules(4, c, t);
        (c, t) = _fill(3, 266, 1);
        (c[0], t[0]) = (2222, 0);
        f.setTraitRules(5, c, t);
        (c, t) = _fill(12, 2222, 0);
        f.setTraitRules(6, c, t);
        (c, t) = _fill(16, 140, 1);
        (c[0], t[0]) = (2222, 0);
        for (uint256 i; i < 6; ++i) {
            t[[1, 3, 4, 10, 11, 14][i]] = 0;
        }
        (c[12], t[12], c[13], t[13]) = (56, 3, 56, 3);
        f.setTraitRules(7, c, t);
        f.addPairRule(IMD6900Frens.PairRule(0, 1, 3, 2, 3));
        f.addPairRule(IMD6900Frens.PairRule(0, 2, 3, 2, 3));
    }

    function _fill(uint8 n, uint16 cap, uint8 tier) internal pure returns (uint16[] memory caps, uint8[] memory tiers) {
        caps = new uint16[](n);
        tiers = new uint8[](n);
        for (uint8 i; i < n; ++i) {
            (caps[i], tiers[i]) = (cap, tier);
        }
    }
}
