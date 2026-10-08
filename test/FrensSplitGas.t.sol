// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FrensPlan} from "../src/FrensPlan.sol";
import {PlaceFrens, PlaceModules} from "../src/FrensPlacement.sol";

contract FrensSplitGasTest is Test {
    function test_CollectionFitsButLegacyFourContractBundleExceedsCap() public {
        vm.etch(
            FrensPlan.CREATE2_DEPLOYER,
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
        );
        uint256 beforeLaunch = vm.snapshotState();
        (uint256 legacy,) = _priceLaunch(true);
        vm.revertToState(beforeLaunch);
        (uint256 collection, address modules) = _priceLaunch(false);
        assertEq(PlaceModules(modules).frens(), FrensPlan.FRENS_AT);
        assertGt(legacy, 1 << 24, "old manifest's four contracts cannot be one launch");
        assertLt(collection + 1_000_000, 1 << 24, "collection retains 1M gas margin");
        emit log_named_uint("legacy four-contract launch", legacy);
        emit log_named_uint("two-contract collection launch", collection);
    }

    function _priceLaunch(bool legacy) internal returns (uint256 total, address modules) {
        bytes[] memory codes = new bytes[](legacy ? 4 : 2);
        codes[0] = vm.getCode("FrensPlacement.sol:PlaceFrens");
        bytes memory moduleCode = vm.getCode("FrensPlacement.sol:PlaceModules");
        if (legacy) {
            codes[1] = vm.getCode("WorkerArt.sol:WorkerArt1");
            codes[2] = vm.getCode("WorkerArt.sol:WorkerArt2");
        }
        (address pf, uint256 creations) = _create(codes[0]);
        if (legacy) {
            (address art1, uint256 g1) = _create(codes[1]);
            (address art2, uint256 g2) = _create(codes[2]);
            creations += g1 + g2;
            codes[3] = abi.encodePacked(moduleCode, abi.encode(pf, art1, art2));
        } else {
            codes[1] = abi.encodePacked(moduleCode, abi.encode(pf));
        }
        uint256 moduleGas;
        (modules, moduleGas) = _create(codes[codes.length - 1]);
        creations += moduleGas;
        assertEq(PlaceModules(modules).frens(), PlaceFrens(pf).frens(), "extra legacy args are silently ignored");
        uint256 length;
        uint256 tokens;
        for (uint256 i; i < codes.length; ++i) {
            assertLe(codes[i].length, 49_152);
            length += codes[i].length;
            for (uint256 k; k < codes[i].length; ++k) {
                tokens += codes[i][k] == 0 ? 1 : 4;
            }
        }
        total = 21_000 + 4 * tokens + creations + 300_000 + 7 * length;
        uint256 floor = 21_000 + 10 * tokens;
        if (floor > total) total = floor;
    }

    function _create(bytes memory code) internal returns (address deployed, uint256 used) {
        uint256 beforeGas = gasleft();
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        used = beforeGas - gasleft();
        assertTrue(deployed != address(0), "creation failed");
    }
}
