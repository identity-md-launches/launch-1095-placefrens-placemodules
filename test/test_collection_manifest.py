"""Offline regression for the factory inputs; uses only Python's standard library."""
import json
import unittest
from pathlib import Path


class CollectionManifestTest(unittest.TestCase):
    def test_collection_is_exactly_two_contracts_in_dependency_order(self):
        manifest = json.loads((Path(__file__).resolve().parents[1] / "launch.json").read_text())
        self.assertEqual(set(manifest), {"kind", "contracts", "notes"})
        self.assertEqual(manifest["kind"], "evm_contracts")
        self.assertEqual(manifest["contracts"], [
            {"contract": "PlaceFrens", "constructorArgs": []},
            {"contract": "PlaceModules", "constructorArgs": ["$contract:PlaceFrens"]},
        ])
        for address in (
            "0x69007Ce82E0BF7981780585afF7c597415903547",
            "0x6900453deFAc8Bb12eabdcf57CCC5a14E7628AeE",
            "0xBbb2796c9C54330788915990Ba36FDDe6dC198cF",
            "0x3F8d1553Cb71C8B5af013Ce985591d9B9BCD9ce2",
            "0x35dA9C0303507ddf708E87F2568EdDf12c47a059",
        ):
            self.assertIn(address, manifest["notes"])
        self.assertNotIn("PlaceModules.renderer()", manifest["notes"])


if __name__ == "__main__":
    unittest.main()
