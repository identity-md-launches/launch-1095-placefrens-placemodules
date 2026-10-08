# Worker Frens collection launch adaptation

## Scope and launch handoff

This round preserves all production Solidity, creation code, salts, compiler settings, dependencies and deployment
scripts. No HIGH or CRITICAL defect was established in this targeted review. The requester's explicit decision is
to record MEDIUM/LOW/INFO findings without changing `src/frens/`, `src/FrensCode.sol`, `src/FrensPlan.sol` or salts.
The four reproduced runtime findings below therefore remain open. No salts were re-mined and no addresses moved.

The collection launch is exactly two nonpayable constructors, called with zero ETH in this order:

| Order | Contract in `src/FrensPlacement.sol` | Arguments |
| --- | --- | --- |
| 1 | `PlaceFrens` | none |
| 2 | `PlaceModules` | `$contract:PlaceFrens` (one address) |

`PlaceFrens` creates FrenPrices and IMD6900Frens (Worker Frens, wFREN, maximum 2222). `PlaceModules` creates its
swapper, ETH minter and workers'/WL gate. The factory makes no initialization calls. The team subsequently runs
`script/frens/DeployFrens.s.sol setup()` with the confirmed `MODULES` and the already-live `RENDERER`
`0x0a2e5e0c1d00fe63ab4e391c052a023cc7a16292` (IMD ART launch 1067, as supplied in the brief). No art contracts belong
in this collection launch. The live renderer was not independently queried on mainnet in this round.

The exact pinned creation code and salts through the standard CREATE2 deployer
`0x4e59b44847b379578588920cA78FbF26c0B4956C` give:

| Contract | Ethereum address |
| --- | --- |
| IMD6900Frens | `0x6900d042460d6bdbe68CE994F4dE36706797CCd4` |
| FrenSwapper | `0x69002297DD7980af0d24249f6a44E7046B1Cb1fb` |
| FrenMinter | `0x46B50a3061Ea692e075231c13bc653FdD1Bedd29` |
| FrenWorkerGate | `0xF83807Ec2E27e1771Fb2594139c1F6925Cfd9B8E` |
| FrenPrices | `0x8f135B75Df156e6346c8525E138bC2BD652146ff` |

These addresses do not depend on the factory caller. The existing exception remains: if the canonical swapper was
pre-placed with an average outside the launch's 2x spot band, PlaceModules creates a replacement with ordinary
CREATE. Read `PlaceModules.swapper()`; the replacement needs its own timelock fee exemption. On a fresh chain without
the standard deployer, the constructors use their own CREATE2 and addresses differ.

The team wallet `0x35dA9C0303507ddf708E87F2568EdDf12c47a059` remains collection owner and governor and gate owner.
Swapper, minter and price table have no owner/governor role to assign. Keeper, relayer, payee and external services
remain the exact FrensPlan values. Neither factory nor placement contract retains any role. The existing explicit
team setup, mint controls and transfer-validator authority are retained as required by the brief.

## Changes made in this round

- **`launch.json` (notes only):** corrected four pre-re-mine addresses and identified the already-live renderer and
  ART launch 1067; updated the gas estimate to the measured 12.45M. The `kind` and two constructor entries were
  already correct and are unchanged. This repairs LOW
  finding `282a96c1580715525a8dfb245cee7d9b5410a91bdd88c51500786e4cef62d722`; it edits the existing handoff without
  introducing a different launch or changing deployment authority.
- **`test/test_collection_manifest.py`:** replaced stale-address assertions with the brief's current addresses;
  cross-checks FrensPlan, `script/placement/addresses.json`, README, this report and manifest notes. Also checks the
  live renderer and that every salt contains no `f2`, `f4` or `ff` byte. The corrected test failed against the original
  handoff documents (two failures), then passed after their repair. It uses only Python's standard library.
- **`README.md`:** corrected the obsolete claim that spent nonces are accepted, distinguished the remaining duplicate
  pending-nonce risk, qualified the unconditional floor-price guarantee, identified the live art launch, and corrected
  `resume()`'s price-band description (warning, not rejection) and the collection gas estimate. Documented the retained risks, keeper nonce discipline
  and the need to keep a swapper wired during an open mint. These are documentation changes, not contract mitigations.
- **`test/FrensResidualRisks.t.sol`:** added four passing reproductions of the retained findings below. The collection
  and spot-pricing tests use the actual pinned creation code, price table, FrensPlan arguments and canonical addresses;
  external tokens, Permit2 and pool state are mocked. A separate subclass exposes the unchanged `_average` for its
  dust test. A passing `test_Risk_...` means the defect still exists; it does not mean it was fixed.
- **`test/FrensLaunchAdaptation.t.sol`:** added `test_OpenAndResumeWarnWhenAverageLags`, covering the already-delivered
  ea109756 script repair: setup succeeds with a normal seed, buys stay paused, spot moves outside the band, and open
  and resume still succeed. No production script changes were needed.
- **`ADAPTATION.md`:** replaced the stale prior-round report with this round's changes, findings and validation. Its
  old assertion that the spent-nonce bug remained unresolved no longer matched the supplied code.

## Imported audit disposition

All six imported findings were confirmed; none was dismissed as non-reproducing. The first four supplied proofs were
copied unchanged to disposable `test/scratch/`, run, and each failed at its stated safety assertion. Their local copies
were removed before the final full build/test so that intentionally failing evidence is not part of the suite.
The delivered tests stand alone without `.imd/reads` or `test/scratch`.

1. **MEDIUM — `a99c13dac6ce8678cded875c24692e2ffcfbc2e16d03e3a98462231a09943fc3`: pending ETH at instantaneous
   POOL4 spot — reproduced, retained.** With two frens out and 1 ETH pending, shifting sqrtPriceX96 from `15 * 2^96`
   to `1.5 * 2^96` lowers `pendingImd` from 225 to 2.25 IMD and the paid mint quote from 112.94025 to 1.56525 IMD.
   Restoring spot gives the new fren a 75.648583333333333333 IMD share. The pool stub reports locked: a completed
   same-transaction swap is not stopped by the collection's Flash guard. `pendingImd` counts WETH by the same formula;
   `buyTreasury` uses the same valuation. The delivered test is `test_Risk_PendingEthSpotPushDilutesExistingHolders`.
   This is a pricing/dilution reproduction with mocked slot changes, not proof of the cost or net profit of a real
   mainnet round trip. In particular it does not validate the imported economic estimate for thin-pool manipulation.
   The existing pair-price average and setup band do not protect POOL4. Paused buys allow pending fees to accumulate;
   operating discipline does not remove this runtime exposure.
2. **LOW — `0cb9cbd74e8107970fd8dc4fd92ff65ba0ad21bb09213ebdf2dd9a65ba5aaf5a`: dust pins the average — reproduced,
   retained.** After 100 blocks with a dust sample followed by a full 50 IMD buy at twice the initial rate, the average
   is only `70000002187499966162064` (1e18 units), instead of exceeding `105000e18`. The full buy makes no change after
   each dust sample. `test_Risk_DustFirstPinsAverageAcrossOneHundredBlocks` preserves this evidence. The arithmetic
   probe establishes the sampling defect; it does not simulate block inclusion, MEV or gas costs. Sampling more than
   the first buy would change the pinned swapper and is deferred by the requester's severity rule.
3. **LOW — `2577a172e288e5de209d328479064d9e87ba61430060320c5ab7d9f1c6480f81`: duplicate pending Permit2 nonce —
   reproduced, retained.** Two pending jobs approved over nonce 5 and the same deadline share a digest and approve
   1 IMD. Settling one payment and revealing both after expiry leaves 0.50 IMD approved, its digest accepted and
   `releaseLapsedJob` reverting `BadJob`. The books exclude that allowance from the floor indefinitely.
   `test_Risk_DuplicatePendingNonceStrandsOnePayment` covers this on the pinned collection. This requires keeper or
   governor error; permissionless callers cannot approve jobs. Persistent unique allocation across pending jobs,
   retries and restarts remains required. The separate *already-spent nonce* bug is fixed in the supplied code.
4. **LOW — `7e2a0f99e1d607fa6c7d8d806cbb01b6c034c8c668287905c1ac32867e415e42`: no swapper underprices reserve —
   reproduced, retained.** With a reserve worth 300.8805 IMD and two frens out, the governor removes the swapper while
   minting stays open. A third fren costs 0.6908 IMD and recycling it pays 100.2935 IMD worth of reserve tokens.
   `test_Risk_UnwiringSwapperAllowsCheapReserveCapture` covers the sequence. This needs a privileged configuration
   change and is not an unprivileged ability to remove the swapper. Close minting during recovery and wire the valid
   replacement directly. Those precautions do not add a runtime guard; the governor can still bypass them.
5. **LOW — `282a96c1580715525a8dfb245cee7d9b5410a91bdd88c51500786e4cef62d722`: stale address handoff — reproduced,
   fixed.** The old manifest test passed by asserting old strings. The new test fails on the old documents and checks
   the current source plan, generated addresses and all handoff documents against the task's addresses. Runtime,
   creation code and salts were not changed to fix this documentation issue.
6. **INFO — `ddd5e4c80d50e113f1f5b950030f1a86b1b87540c11ac6b04221de6e4b049755`: trust assumptions — confirmed,
   retained.** The team configures renderer, modules, traits, WL and mint opening after deployment. The governor can
   close minting, pause floor buys, replace the swapper/gate, change keeper/relayer/payee and tiers/caps, and transfer
   governorship in one step. A governor-selected swapper can retain each approved floor buy. Owner/governor can block
   peer transfers through a rejecting validator (floor trades bypass it); the owner/governor can change the renderer
   until art is frozen. Relayer chooses valid reveal combinations; keeper authorizes jobs. Direct IMD6900 donations
   and unsupported royalty tokens have no recovery path; only booked IMD6900 counts in the reserve. Tiers are balance
   snapshots, so borrowing outside an active Uniswap v4 unlock can reach a tier. Distributor status and pair-hook fee
   exemption remain external timelock dependencies. Existing review tests establish constructor setup, privileged
   transfer blocking and mint closure; existing floor tests establish per-buy swapper authority. Placement runtime
   opcode scans and the fresh-chain creation trace cover the forbidden operations without changing these powers.

## Repairs already present when this assignment arrived

The ea109756 fixes described in README were supplied code, not edits in this round: pending ETH/WETH now counts in
mint and treasury pricing (`dc3bd30d`), unswept IMD is swept before recycling/treasury pricing (`b7d35d29`), spent Permit2
nonces are rejected, and open/resume warn on a lagging average while setup remains strict. Existing tests include
`test_PendingEthCountsInTheMintPrice`, `test_UnsweptImdCountsInTheTreasuryPrice`, `test_KeeperCannotApproveASpentNonce`
and `test_Fix_SpentNonceIsRefused`; the activation regression added here covers the last repair. The removed
`lowerMinTier` and re-mined salts were also supplied. Their historical old-code results are not claimed as newly run
here. The newer spot-pricing and duplicate-pending-nonce findings are distinct from those repaired defects.

Earlier bootstrap and pre-placement assumptions remain: strategy frens must exist before fees/public minting, a
launch-block price seed can itself be manipulated, a replacement swapper needs its own exemption, and the keeper must
use unique pending nonces. None of the documented script safeguards prevents direct governor calls bypassing them.

## Validation and limits

With Forge 1.8.3 and the unchanged solc 0.8.30 / optimizer 200 / via-IR / Cancun / bytecode_hash none configuration:

- `forge build`: passed, with existing compiler/lint warnings. PlaceFrens and PlaceModules have the required
  nonpayable ABIs and runtime lengths 193 and 358 bytes. IMD6900Frens remains 24,441 bytes (below EIP-170's 24,576).
- `forge test -vv`: **196 passed, 0 failed, 5 skipped**, across 19 suites. This includes all four new retained-risk
  tests, the activation regression, prior money/nonce repairs, factory roles, fresh-chain trace, code/source identity,
  CREATE2 predictions, admission scans and invariants. The two transient-storage validator regressions pass on this
  Forge version; Forge 1.4 users need `--isolate` as specified in the brief.
- No `MAINNET_RPC_URL` was supplied: the five existing RPC-dependent suites skipped and no mainnet fork claim is
  made for this round. Live distributor status, exemptions, timelock execution and renderer are not verified here.
- `test_EachLaunchFitsOneTransaction`: collection **12,451,232 gas** including its calldata and launcher allowance,
  leaving **4,325,984 gas** below 2^24 and passing the required 1M margin. The brief's 12.3M was approximate;
  this round did not change launch code. The independent art launch remains 13,605,058 gas in that test.
- `python3 test/test_collection_manifest.py`: **4 passed**, including current handoff addresses and salt bytes.
- SHA-256 comparison against the initial local snapshot: **139 source, deployment-script, configuration and
  dependency files unchanged**. Only the six files listed above changed or were added. No dependency installation
  or network access was needed; all new tests use vendored libraries or Python's standard library.

No wallet key was accessed or transaction broadcast. The review used the supplied protected probe, security adapter, pinned REFERENCE and LICENSE,
launch contracts/plan, application contracts, setup script and relevant tests. No Slither or Mythril run is claimed.
The supplied protected probe has exact pragma 0.8.26 while the project pins solc 0.8.30; existing `FrensFactoryReviewTest`
rehearses the same constructor-only CREATE2 interface under the unchanged project compiler, and existing admission
checks cover sizes, opcodes, code/source identity and deterministic addresses. This targeted local review does not
independently audit external mainnet hooks, validator, x402 service, keeper or deployed art.
