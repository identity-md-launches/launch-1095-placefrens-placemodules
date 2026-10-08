#!/usr/bin/env python3
"""The IMD swarm's launch of the frens, planned to the byte: where every contract lands on Ethereum, decided here.

IMD deploys a launch from its own deployer, so nothing it creates directly has an address anyone knows in advance. The
launch's two contracts (src/FrensPlacement.sol) therefore create the frens and their modules through the standard
CREATE2 deployer (0x4e59b448…956C, the same address on every chain), whose addresses depend only on a salt and the
exact creation code. This fixes that code (src/FrensCode.sol: the creation code forge builds from src/frens/ with
foundry.toml's settings, as data, so however IMD compiles the launch the children are these bytes), mines the salts
(the frens and the swapper start 0x6900…) and writes the addresses (src/FrensPlan.sol). test/FrensPlacement.t.sol
checks that src/FrensCode.sol is exactly what the sources build, and that the launch lands where FrensPlan says.

  forge build && python3 script/placement/gen.py [frens prefix, 6900] [--remine]

The salts already in src/FrensPlan.sol stay while they still put the frens and the swapper at their prefix (the plan
doesn't move when nothing changed); --remine mines new ones.
"""
import json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "../.."))
CREATE2_DEPLOYER = "0x4e59b44847b379578588920cA78FbF26c0B4956C"
A = {  # the frens' constructor arguments, and the modules': script/frens/DeployFrens.s.sol has the same
    "OWNER": "0x35dA9C0303507ddf708E87F2568EdDf12c47a059",  # the team wallet: owner and governor
    "IMD": "0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7",
    "IMD6900": "0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F",
    "IDENTITY": "0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D",
    "PERMIT2": "0x000000000022D473030F116dDEE9F6B43aC78BA3",
    "X402_PROXY": "0x402085c248EeA27D92E8b30b2C58ed07f9E20001",
    "IMD_PAY_TO": "0xC94400e90bB652AFA02740bFf50824E14069c133",  # the relayer's job payer: each mint's job money pays it back
    "KEEPER": "0x75521bC4b21CAFD5bbc008A76D0988f777BD5888",
    "RELAYER": "0x3c038c9D0ab5532b5cae78dABeda916e34af3D5E",
    "POOL_MANAGER": "0x000000000004444c5dc75cB358380D2e3dE08A90",
    "PAIR_HOOK": "0x667f4621030aCfAfb1bD0B64d33610A8567f2A44",
    "POOL4_HOOK": "0xc6C965Bd164c483e87d0B550671798e9A3602840",
}
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
PREFIX = {"FRENS": ARGS[0] if ARGS else "6900", "SWAPPER": "6900"}

def cast(*args):
    return subprocess.run(["cast", *args], check=True, capture_output=True, text=True,
                          env={**os.environ, "FOUNDRY_DISABLE_NIGHTLY_WARNING": "1"}).stdout.strip()

def creation(name):
    return json.load(open(os.path.join(ROOT, f"out/{name}.sol/{name}.json")))["bytecode"]["object"][2:]

def enc(types, *vals):
    return cast("abi-encode", f"f({','.join(types)})", *vals)[2:]

def keccak(hexdata):
    return cast("keccak", "0x" + hexdata)

def at(salt, init_hex):
    """CREATE2 from the standard deployer: keccak(0xff ++ deployer ++ salt ++ keccak(initcode))[12:]"""
    h = keccak("ff" + CREATE2_DEPLOYER[2:].lower() + salt[2:] + keccak(init_hex)[2:])
    return cast("to-check-sum-address", "0x" + h[-40:])

# IMD's admission scan reads code as instructions and refuses CALLCODE, DELEGATECALL and SELFDESTRUCT bytes; the
# compiler may keep a salt as raw data after the code (no PUSH in front), so a salt holding one of them can trip the
# scan wherever it sits. Only clean salts are kept or mined.
BAD = ("f2", "f4", "ff")
def clean(salt):
    h = salt[2:].lower()
    return not any(h[i:i + 2] in BAD for i in range(0, len(h), 2))

def kept(name, prefix, init_hex):
    """The salt FrensPlan already has, while it still puts the contract at the prefix (the plan doesn't move)"""
    try:
        m = re.search(name + r"_SALT = (0x[0-9a-fA-F]{64});", open(os.path.join(ROOT, "src/FrensPlan.sol")).read())
    except FileNotFoundError:
        return None
    if m and "--remine" not in sys.argv:
        a = at(m.group(1), init_hex)
        if a[2:].lower().startswith(prefix.lower()) and clean(m.group(1)):
            return m.group(1), a
    return None

def mine(name, prefix, init_hex):
    k = kept(name, prefix, init_hex)
    if k:
        return k
    while True:
        out = cast("create2", "--starts-with", prefix, "--deployer", CREATE2_DEPLOYER, "--init-code-hash", keccak(init_hex), "--threads", str(os.cpu_count()))
        # newer cast prints the result as "address<TAB>salt" on stdout (the rest on stderr); older ones as "Address:" / "Salt:" lines
        tsv = re.search(r"^(0x[0-9a-fA-F]{40})\s+(0x[0-9a-fA-F]{64})\s*$", out, re.M)
        if tsv:
            s, addr = tsv.group(2), tsv.group(1)
        else:
            salt = re.search(r"Salt:\s*(0x[0-9a-fA-F]{64})|Salt:\s*(\d+)", out)
            addr = re.search(r"Address:\s*(0x[0-9a-fA-F]{40})", out).group(1)
            s = salt.group(1) or "0x%064x" % int(salt.group(2))
        if clean(s):
            return s, addr

def main():
    code = {n: creation(n) for n in ("FrenPrices", "IMD6900Frens", "FrenSwapper", "FrenMinter", "FrenWorkerGate")}
    salts, addrs = {}, {}
    salts["PRICES"] = "0x" + "00" * 31 + "01"
    addrs["PRICES"] = at(salts["PRICES"], code["FrenPrices"])
    frens_init = code["IMD6900Frens"] + enc(["address"] * 10, A["OWNER"], A["IMD"], A["IMD6900"], A["IDENTITY"], A["PERMIT2"],
                                            A["X402_PROXY"], A["IMD_PAY_TO"], A["KEEPER"], A["RELAYER"], addrs["PRICES"])
    salts["FRENS"], addrs["FRENS"] = mine("FRENS", PREFIX["FRENS"], frens_init)
    swapper_init = code["FrenSwapper"] + enc(["address"] * 6, A["POOL_MANAGER"], A["IMD"], A["IMD6900"], addrs["FRENS"], A["PAIR_HOOK"], A["POOL4_HOOK"])
    salts["SWAPPER"], addrs["SWAPPER"] = mine("SWAPPER", PREFIX["SWAPPER"], swapper_init)
    minter_init = code["FrenMinter"] + enc(["address"] * 4, A["POOL_MANAGER"], addrs["FRENS"], A["POOL4_HOOK"], A["PAIR_HOOK"])
    salts["MINTER"] = "0x" + "00" * 31 + "02"
    addrs["MINTER"] = at(salts["MINTER"], minter_init)
    gate_init = code["FrenWorkerGate"] + enc(["address"] * 4, A["OWNER"], addrs["FRENS"], A["IDENTITY"], A["IMD6900"])
    salts["GATE"] = "0x" + "00" * 31 + "03"
    addrs["GATE"] = at(salts["GATE"], gate_init)

    lib = "\n".join(f"    bytes internal constant {k} = hex\"{v}\";" for k, v in (
        ("PRICES", code["FrenPrices"]), ("FRENS", code["IMD6900Frens"]), ("SWAPPER", code["FrenSwapper"]),
        ("MINTER", code["FrenMinter"]), ("GATE", code["FrenWorkerGate"])))
    open(os.path.join(ROOT, "src/FrensCode.sol"), "w").write(f"""// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title FrensCode - the frens' contracts' creation code, as data
/// @notice GENERATED by script/placement/gen.py from what forge builds of src/frens/ (foundry.toml's settings: solc
///         0.8.30, via-IR, 200 runs, cancun, no metadata hash): never edit by hand. As data, it is the same whatever
///         compiles the launch, so the CREATE2 addresses in FrensPlan hold; test_CodeIsWhatTheSourcesBuild proves these
///         bytes are the sources' own. Constructor arguments are added at the launch.
library FrensCode {{
{lib}
}}
""")
    plan = "\n".join(
        [f"    address internal constant {k} = {cast('to-check-sum-address', v)};" for k, v in A.items()]
        + [f"    bytes32 internal constant {k}_SALT = {v};" for k, v in salts.items()]
        + [f"    /// @notice where it lands on Ethereum (any chain with the CREATE2 deployer)\n    address internal constant {k}_AT = {cast('to-check-sum-address', v)};" for k, v in addrs.items()])
    open(os.path.join(ROOT, "src/FrensPlan.sol"), "w").write(f"""// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title FrensPlan - who the frens' contracts are made for, and where they land
/// @notice GENERATED by script/placement/gen.py: never edit by hand. The salts are mined so the frens and the swapper
///         start 0x6900…; the addresses follow from them, the standard CREATE2 deployer and FrensCode.
library FrensPlan {{
    /// @notice The standard CREATE2 deployer (Arachnid's, the same address on every chain)
    address internal constant CREATE2_DEPLOYER = {CREATE2_DEPLOYER};
{plan}
}}
""")
    json.dump(addrs, open(os.path.join(HERE, "addresses.json"), "w"), indent=1)
    for k, v in addrs.items(): print(f"{k:8} {v}  salt {salts[k]}")

if __name__ == "__main__":
    main()
