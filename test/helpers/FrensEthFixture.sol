// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PlaceFrens, PlaceModules} from "src/FrensPlacement.sol";
import {FrensPlan} from "src/FrensPlan.sol";
import {IMD6900Frens} from "src/frens/IMD6900Frens.sol";
import {FrenMinter} from "src/frens/FrenMinter.sol";
import {FrenWorkerGate} from "src/frens/FrenWorkerGate.sol";
import {FrensRules} from "../frens/FrensRules.sol";

contract EthFixtureToken is ERC20 {
    function name() public pure override returns (string memory) {
        return "Offline token";
    }

    function symbol() public pure override returns (string memory) {
        return "OFF";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // IMD uses explicit Permit2 approvals; Solady's default implicit infinite allowance would
    // invent a liability in the collection's accounting (as in the existing PlainImd fixture).
    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }
}

interface IEthMinterCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @dev Offline model of the v4 boundary used by FrenMinter, NOT an AMM or a mainnet-hook simulation.
/// Enforces signed deltas, authenticated callbacks, settlement before relock, and inventory-backed take.
/// Output is 1000 IMD/ETH or 7 IMD6900/IMD. Partial/excess fills are configured after fee effects.
/// Quotes really execute the callback and unwind storage writes on revert; they are not canned responses.
contract EthMinterPoolModel {
    bool public unlocked;
    address public locker;
    int256 public ethDelta;
    int256 public imdDelta;
    int256 public floorDelta;
    uint256 public unlocks;
    uint256 public swaps;
    uint256 public fillBps;
    uint256 public bonus;
    bytes internal failure;

    error PoolLocked();
    error AlreadyUnlocked();
    error CurrencyNotSettled();
    error SwapAmountCannotBeZero();

    modifier onlyLocker() {
        if (!unlocked || msg.sender != locker) revert PoolLocked();
        _;
    }

    function configure(uint256 fillBps_, uint256 bonus_) external {
        require(fillBps_ <= 10_000);
        fillBps = fillBps_;
        bonus = bonus_;
    }

    function setFailure(bytes calldata reason) external {
        failure = reason;
    }

    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(uint256(1) << 96); // initialized unit-price pool, for the placed swapper's constructor
    }

    function exttload(bytes32) external view returns (bytes32) {
        return bytes32(uint256(unlocked ? 1 : 0));
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (unlocked) revert AlreadyUnlocked();
        unlocked = true;
        locker = msg.sender;
        ++unlocks;
        result = IEthMinterCallback(msg.sender).unlockCallback(data);
        if (ethDelta != 0 || imdDelta != 0 || floorDelta != 0) revert CurrencyNotSettled();
        unlocked = false;
        locker = address(0);
    }

    function swap(PoolKey calldata key, SwapParams calldata p, bytes calldata hookData)
        external
        onlyLocker
        returns (BalanceDelta delta)
    {
        if (failure.length != 0) {
            bytes memory reason = failure;
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
        if (p.amountSpecified == 0) revert SwapAmountCannotBeZero();
        require(hookData.length == 0 && key.tickSpacing == 60, "unexpected pool parameters");
        ++swaps;
        if (Currency.unwrap(key.currency0) == address(0)) {
            require(Currency.unwrap(key.currency1) == FrensPlan.IMD, "wrong IMD");
            require(address(key.hooks) == FrensPlan.POOL4_HOOK && key.fee == 10_000, "wrong ETH pool");
            require(p.zeroForOne && p.sqrtPriceLimitX96 == TickMath.MIN_SQRT_PRICE + 1, "wrong ETH direction");
            uint256 ethIn;
            uint256 imdOut;
            if (p.amountSpecified > 0) {
                imdOut = uint256(p.amountSpecified) * fillBps / 10_000 + bonus;
                ethIn = (imdOut + 999) / 1000;
            } else {
                ethIn = uint256(-p.amountSpecified);
                imdOut = ethIn * 1000;
            }
            ethDelta -= int256(ethIn);
            imdDelta += int256(imdOut);
            require(ethIn <= uint256(uint128(type(int128).max)) && imdOut <= uint256(uint128(type(int128).max)));
            return toBalanceDelta(-int128(int256(ethIn)), int128(int256(imdOut)));
        }
        require(Currency.unwrap(key.currency0) == FrensPlan.IMD6900, "wrong floor token");
        require(Currency.unwrap(key.currency1) == FrensPlan.IMD, "wrong pair token");
        require(address(key.hooks) == FrensPlan.PAIR_HOOK && key.fee == 0, "wrong pair hook");
        require(!p.zeroForOne && p.amountSpecified < 0, "wrong pair direction");
        require(p.sqrtPriceLimitX96 == TickMath.MAX_SQRT_PRICE - 1, "wrong pair limit");
        uint256 input = uint256(-p.amountSpecified);
        uint256 output = input * 7;
        require(output <= uint256(uint128(type(int128).max)));
        imdDelta -= int256(input);
        floorDelta += int256(output);
        return toBalanceDelta(int128(int256(output)), -int128(int256(input)));
    }

    function settle() external payable onlyLocker returns (uint256) {
        require(ethDelta <= 0 && msg.value <= uint256(-ethDelta), "overpayment");
        ethDelta += int256(msg.value);
        return msg.value;
    }

    function take(Currency currency, address to, uint256 amount) external onlyLocker {
        require(Currency.unwrap(currency) == FrensPlan.IMD, "unexpected currency");
        require(imdDelta >= 0 && amount <= uint256(imdDelta), "unearned credit");
        imdDelta -= int256(amount);
        require(EthFixtureToken(FrensPlan.IMD).transfer(to, amount));
    }
}

abstract contract FrensEthFixture is Test, FrensRules {
    IMD6900Frens internal frens;
    FrenMinter internal minter;
    FrenWorkerGate internal gate;
    EthFixtureToken internal imd;
    EthMinterPoolModel internal manager;
    address internal alice;

    function setUp() public virtual {
        vm.etch(
            FrensPlan.CREATE2_DEPLOYER,
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
        );
        vm.etch(FrensPlan.IMD, type(EthFixtureToken).runtimeCode);
        vm.etch(FrensPlan.IMD6900, type(EthFixtureToken).runtimeCode);
        vm.etch(FrensPlan.IDENTITY, type(EthFixtureToken).runtimeCode);
        vm.etch(FrensPlan.POOL_MANAGER, type(EthMinterPoolModel).runtimeCode);
        imd = EthFixtureToken(FrensPlan.IMD);
        manager = EthMinterPoolModel(FrensPlan.POOL_MANAGER);
        manager.configure(10_000, 0);
        imd.mint(address(manager), 1e36);
        PlaceFrens collection = new PlaceFrens();
        PlaceModules modules = new PlaceModules(collection);
        frens = IMD6900Frens(payable(collection.frens()));
        minter = FrenMinter(modules.minter());
        gate = FrenWorkerGate(modules.gate());
        assertEq(address(frens), FrensPlan.FRENS_AT);
        assertEq(address(minter), FrensPlan.MINTER_AT);
        assertEq(address(gate), FrensPlan.GATE_AT);
        assertEq(modules.swapper(), FrensPlan.SWAPPER_AT);
        vm.startPrank(FrensPlan.OWNER);
        _rules(frens, [uint16(1598), 312, 312]);
        frens.sealTraits();
        frens.setModules(modules.swapper(), address(gate));
        // Isolate ETH mint settlement; floor buys have their own existing invariant suite.
        // Keep the real swapper wired so quote still reads the actual collection's accounting.
        frens.setParams(1, 0, 0);
        frens.setMintOpen(true);
        vm.stopPrank();
        alice = makeAddr("offline ETH minter alice");
        vm.deal(alice, 100 ether);
    }

    function _openPublic() internal {
        vm.prank(FrensPlan.OWNER);
        gate.openPublic();
    }

    function _wl(address account, uint256 amount) internal {
        vm.prank(FrensPlan.OWNER);
        gate.setWlRoot(keccak256(bytes.concat(keccak256(abi.encode(account, amount)))));
        vm.prank(account);
        gate.claimWl(amount, new bytes32[](0), account);
    }

    function _snapshot(address account) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                account.balance,
                address(manager).balance,
                address(minter).balance,
                imd.balanceOf(account),
                imd.balanceOf(address(manager)),
                imd.balanceOf(address(minter)),
                imd.balanceOf(address(frens)),
                imd.allowance(address(minter), address(frens)),
                frens.totalMinted(),
                frens.nextRequestId(),
                frens.jobBudget(),
                frens.floorImd(),
                frens.openLowTier(),
                gate.credits(account),
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
