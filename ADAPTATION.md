# Worker Frens collection launch adaptation

## Scope

This assignment preserves the delivered, audited contracts and their deterministic addresses. No byte in
`src/frens/`, `src/art/`, `src/FrensCode.sol`, `src/FrensPlan.sol`, or `src/FrensPlacement.sol` was changed.
The compiler configuration, salts, dependencies and art hashes are unchanged. No dependency was installed, no wallet
key was read and no transaction was broadcast. This document replaces the previous adaptation report, which still
claimed a four-contract launch and described changes from the earlier audit as current work.

The collection launch now specifies exactly:

| Order | Contract | Nonpayable constructor arguments |
| --- | --- | --- |
| 1 | `PlaceFrens` | none |
| 2 | `PlaceModules` | `$contract:PlaceFrens` |

`PlaceFrens` creates FrenPrices and IMD6900Frens (Worker Frens, wFREN, 2222 maximum); `PlaceModules` creates the
swapper, ETH minter and worker/WL gate. The separate art launch is WorkerArt1, WorkerArt2, WorkerFrensRenderer.
Neither launch needs factory initialization calls. After both launches, the team configures the collection with
`script/frens/DeployFrens.s.sol setup()`. This post-launch configuration is explicitly required by the brief.

| Contract | Ethereum address |
| --- | --- |
| IMD6900Frens | `0x69007Ce82E0BF7981780585afF7c597415903547` |
| FrenSwapper | `0x6900453deFAc8Bb12eabdcf57CCC5a14E7628AeE` unless the launch replaces a skewed pre-placement |
| FrenMinter | `0xBbb2796c9C54330788915990Ba36FDDe6dC198cF` |
| FrenWorkerGate | `0x3F8d1553Cb71C8B5af013Ce985591d9B9BCD9ce2` |
| FrenPrices | `0x8f135B75Df156e6346c8525E138bC2BD652146ff` |

Owner and governor remain the specified team wallet, `0x35dA9C0303507ddf708E87F2568EdDf12c47a059`; the gate's owner
is the same wallet. Keeper, relayer and job recipient remain FrensPlan's values. The factory and placement contracts
retain no role. The unchanged constructors use the standard CREATE2 deployer when present, and their own CREATE2
without calls to pre-existing contracts on a fresh chain.

## Changes and their tests

- **`launch.json`:** removed the two art entries and extra PlaceModules arguments, updated the deterministic addresses,
  and removed obsolete claims about PlaceModules deploying/checking a renderer. Required by the collection-only brief
  and finding `e316aa67…`. The explicit audit repair takes precedence over the background reference's advice to leave
  manifest authoring to a later assignment. `test/test_collection_manifest.py` verifies the exact two entries and
  notes' addresses using the Python standard library. `test/FrensSplitGas.t.sol` reproduces the old bundle's gas failure,
  including its silently ignored extra constructor words, and verifies the split collection has over 1M gas margin.
- **`script/frens/DeployFrens.s.sol`:** requires a deployed `MODULES`, reads all four addresses from it, checks their
  dependency relationships and the pinned Ethereum collection address, and removes per-address environment overrides.
  This prevents setup from silently choosing the rejected pre-placed swapper (`8bf00c57…`). `resume()` verifies the
  actual swapper's fee exemption, distributor status and current wiring. Tests cover missing/wrong modules, foreign
  dependencies, the normal path, and a rejected pre-placement with an unexempt replacement.
- **The same script:** setup pauses floor buys before the first mint even if the collection is already a distributor.
  `firstFrens()` rejects zero count, mismatched minters and an initial mint before buys have been paused. New `open()`
  and strengthened `resume()` refuse a floor without frens out. This implements the audit's allowed operational
  mitigation for `e336c1dc…`; the mandatory recipient remains the specified IMD6900 strategy. Tests reproduce the
  original capture and show that bootstrapping before fees prevents the public capture. The governor can still bypass
  these script checks; they do not change the pinned collection's behavior.
- **The same script:** setup/open/resume check the swapper's nonzero average and spot against the existing 2x band
  when the pool manager is present. This detects a launch-block seed that remains skewed after the pool price returns
  (`e8deb536…`). Tests reproduce the 100x launch-block skew and setup's refusal. This is a mitigation, not an independent
  price oracle or a launch-block manipulation fix. Internal virtual input readers let tests supply script inputs
  without changing shared process environment variables.
- **`test/FrensLaunchAdaptation.t.sol`:** regression tests for those script changes plus explicit, passing reproductions
  of the remaining pinned-runtime issues. A `test_Risk_…` test asserts the vulnerability still exists; it must not be
  read as proving the contract issue fixed. Assets and external services are mocked; collection deployment uses the
  exact pinned creation code, price table and Ethereum addresses.
- **`test/FrensLaunchFailures.t.sol`:** updates the missing-placement regression for required MODULES, with an input
  override that avoids process-global environment mutations.
- **`test/FrensPlacement.t.sol`:** the workers-first fork test now uses a test-only salt distinct from the queued
  production batch (`d82cb2d8…`) and rehearses mandatory firstFrens before opening or moving fees. The production batch,
  its salt, and its targets are unchanged.
- **`README.md`:** makes the bootstrap order mandatory; explains MODULES, replacement-swapper exemptions, launch-block
  price checks and manual governor recovery; restricts listings to ETH/WETH; records the required keeper nonce
  discipline. Removed the instruction to regenerate the pinned code/salts. Corrected the universal floor guarantee
  and identified the art as a separate launch.

## Imported audit disposition

1. **`e316aa67…`, stale four-contract manifest — reproduced and fixed.** Its extra PlaceModules words are ignored;
   bundling the art breaches the transaction cap. The manifest now has the requested two contracts only.
2. **`e336c1dc…`, floor before first mint — reproduced; operational mitigation implemented.** On the actual pinned
   price table, a two-fren first request pays about 1.38 IMD while recycling one can capture over 425 IMD of a donated
   floor. The precise 0.69-per-fren proof uses a synthetic table; the production curve's tiny difference does not close
   the issue. The team must mint first to the strategy while minting is closed and buys are paused, before fees move,
   buys resume, or the workers/WL/public window opens. Setup and activation scripts now enforce the relevant order.
   Direct unsolicited transfers and direct governor calls remain possible; this is not a contract-level fix.
3. **`e8deb536…`, launch-block spot seed — reproduced; remains a trust assumption with activation mitigation.** A pool
   stub at 2^96/26 seeds about 676 IMD6900 per IMD; returning to 2^96/265 leaves spot around 70,225 while the average
   stays skewed. The launch's same-block band check passes by construction. Private submission and a later independent
   price check are required operational precautions, but the deployer's relay policy has not been verified. README
   describes governor recovery via a new unchanged FrenSwapper, setModules and a new fee-exemption batch. The normal
   script intentionally refuses this manual recovery's changed wiring, so it must not be rerun to undo the recovery.
4. **`8bf00c57…`, setup selects rejected swapper / wrong exemption — reproduced and fixed in the script.** Previously
   missing MODULES defaulted to SWAPPER_AT. Now MODULES is mandatory and its swapper is authoritative. A replacement
   must be fee-exempt itself before resume. The queued batch cannot be assumed to cover a replacement.
5. **`75823c0…`, spent Permit2 nonce — reproduced and unresolved in pinned bytecode.** Approving spent nonce 42 books
   another 0.50 IMD allowance; expiry cannot reclaim it and a new approval fails without another job budget. Adding
   `_spent(nonce)` to approveJob would modify explicitly prohibited `src/frens/IMD6900Frens.sol` and move the timelock's
   collection address. No keeper implementation was supplied to patch. README requires checking nonceBitmap and
   durable unique allocation across pending jobs and restarts. That operational requirement does not fix or recover
   an allowance already stranded. This remaining defect needs requester attention before treating the audit as closed.
6. **`ab504e43…`, unsupported royalty tokens — reproduced; listing restriction documented.** The royalty receiver is
   always the collection. Review of its external methods finds no arbitrary-token withdrawal; a test confirms unrelated
   balances survive the available floor operations. ETH/WETH-only listings are the audit's permitted remedy, without
   adding a rescue function to pinned bytecode. Marketplace compliance with that restriction is outside this repository.
   Direct IMD6900 donations remain unbooked; $IMD has the existing sweep route.
7. **`d82cb2d8…`, already queued timelock batch — production-state collision avoided in the test.** The fork test used
   the production salt with identical targets, reproducing an operation-ID collision whenever that batch is queued.
   A separate test-only salt removes that dependency. A read-only mainnet check in this round (head 26,149,066) returned getTimestamp = 1791649787 and isOperationDone = false for operation 0x6ebf60b5d6a49cec8df7fdb89ce96061ddb4316aaba0dc170007c223634c1ffa, confirming the collision. This is a test fix, not a change to the live timelock.
8. **`2fe075df…`, privileged behavior — confirmed and retained as explicitly requested.** The existing factory/role
   tests cover team setup, closing minting, rejecting holder transfers and no launcher roles. The governor can change
   the swapper/gate and caps, and can strand mint quoting by removing a swapper with a live reserve. The owner/governor
   validator can block peer transfers; floor trades bypass it. The governor's chosen swapper can spend floor IMD.
   setGovernor remains one-step. No new minting, pausing or admin capabilities were added to deployed contracts.
9. **`70043683…`, coverage report — historical evidence, not a defect or a claim of checks run in this assignment.**
   This round read the supplied protected probe, pinned security reference/license, launch constructors/plan, affected
   setup and timelock scripts, relevant collection/swapper/gate behavior and existing tests. It is an adaptation and
   targeted reproduction, not a new full audit of the art, Uniswap, validator, x402 service or external keeper.

No substantive finding was dismissed as non-reproducing. Explicit source immutability prevents a complete
contract-level repair of the spent-nonce bug; the floor and seed mitigations still require the documented operator
behavior. Do not interpret passing regression tests as closing those residual risks.

## Validation

With the unchanged project configuration (solc 0.8.30, optimizer 200, via-IR, Cancun, bytecode_hash none), Forge 1.8.3:

- `forge build --offline`: passed; compiler/lint warnings remain. Both placement ABIs are nonpayable;
  PlaceFrens takes no arguments and PlaceModules takes exactly one address.
- `forge test --offline -vv`: **189 passed, 0 failed, 5 skipped**, across 17 suites. The skipped entries are the
  existing RPC-dependent fork suites. The untouched baseline had 173 passed, 0 failed, 5 skipped.
- `MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --offline --match-contract FrensPlacementForkTest
  --match-test 'test_fork_(SetupDrawsWithTheLaunchsArt|TheWholeRoad|WorkersFirstThenPublic)' -vv`: **3 passed**.
  This checks live setup, first strategy mints, workers/WL opening, timelock execution, actual fee exemption,
  resume, and handover. No transaction was broadcast. Other fork suites were not rerun this round.
- `python3 test/test_collection_manifest.py`: passed.
- Existing `test_EachLaunchFitsOneTransaction`: **12,308,310 gas** for the collection and **13,605,058 gas** for
  the independent art launch, including the documented calldata/launcher pricing. Both retain over 1M gas
  below 16,777,216. The new raw-CREATE reproduction prices the legacy bundle at **23,723,070 gas**, versus
  **13,340,309 gas** for the split collection under its more conservative measurement; both confirm the split.
- Existing code/source identity, plan/address derivation, factory, role, fresh-chain and opcode/size tests pass.
  SHA-256 comparison of 98 protected source/configuration/dependency files found no changes.
- `git diff --check`: passed. No Slither or Mythril run is claimed.

All delivered tests stand alone without the supplied `.imd/reads` or disposable `test/scratch` inputs.
The supplied protected probe pins pragma 0.8.26, while this project pins solc 0.8.30; its existing equivalent
`FrensFactoryReviewTest` rehearses the factory's constructor-only CREATE2 pattern under the project's compiler.
The existing admission scans cover forbidden opcodes and size, and fresh-chain tests cover external calls.
