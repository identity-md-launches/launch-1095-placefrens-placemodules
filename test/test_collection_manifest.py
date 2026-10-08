"""Offline regression for the factory inputs; uses only Python's standard library."""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = {
    "FRENS": "0x6900d042460d6bdbe68CE994F4dE36706797CCd4",
    "SWAPPER": "0x69002297DD7980af0d24249f6a44E7046B1Cb1fb",
    "MINTER": "0x46B50a3061Ea692e075231c13bc653FdD1Bedd29",
    "GATE": "0xF83807Ec2E27e1771Fb2594139c1F6925Cfd9B8E",
    "PRICES": "0x8f135B75Df156e6346c8525E138bC2BD652146ff",
}
OWNER = "0x35dA9C0303507ddf708E87F2568EdDf12c47a059"
RENDERER = "0x0a2e5e0c1d00fe63ab4e391c052a023cc7a16292"


class CollectionManifestTest(unittest.TestCase):
    def test_collection_is_exactly_two_contracts_in_dependency_order(self):
        manifest = json.loads((ROOT / "launch.json").read_text())
        self.assertEqual(set(manifest), {"kind", "contracts", "notes"})
        self.assertEqual(manifest["kind"], "evm_contracts")
        self.assertEqual(manifest["contracts"], [
            {"contract": "PlaceFrens", "constructorArgs": []},
            {"contract": "PlaceModules", "constructorArgs": ["$contract:PlaceFrens"]},
        ])
        for address in (*EXPECTED.values(), OWNER, RENDERER):
            self.assertIn(address, manifest["notes"])
        self.assertNotIn("PlaceModules.renderer()", manifest["notes"])

    def test_plan_and_generated_addresses_match_the_approved_brief(self):
        plan = (ROOT / "src/FrensPlan.sol").read_text()
        addresses = dict(re.findall(r"address internal constant (\w+)_AT = (0x[0-9a-fA-F]{40});", plan))
        self.assertEqual(addresses, EXPECTED)
        self.assertEqual(json.loads((ROOT / "script/placement/addresses.json").read_text()), EXPECTED)
        self.assertIn(f"address internal constant OWNER = {OWNER};", plan)

    def test_handoff_documents_use_current_addresses_and_live_art(self):
        for filename in ("README.md", "ADAPTATION.md"):
            with self.subTest(filename=filename):
                contents = (ROOT / filename).read_text()
                for address in (*EXPECTED.values(), OWNER, RENDERER):
                    self.assertIn(address, contents)

    def test_mined_salts_have_no_admission_escape_bytes(self):
        plan = (ROOT / "src/FrensPlan.sol").read_text()
        salts = dict(re.findall(r"bytes32 internal constant (\w+)_SALT = 0x([0-9a-fA-F]{64});", plan))
        self.assertEqual(set(salts), set(EXPECTED))
        for name, salt in salts.items():
            with self.subTest(salt=name):
                self.assertFalse({0xf2, 0xf4, 0xff}.intersection(bytes.fromhex(salt)))


if __name__ == "__main__":
    unittest.main()
