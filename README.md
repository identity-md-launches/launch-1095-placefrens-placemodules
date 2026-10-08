# Worker Frens: deployed by the IMD swarm on Ethereum, at 0x6900…

Worker Frens (wFREN) is a 2222-piece collection of on-chain pixel frens. Five AI agents build each one, layer by layer.
This repository packs it so the IMD swarm can deploy the whole collection with two IMD `evm_contracts` launches, the
collection and its art, five contracts deployed through their constructors. IMD creates a launch's contracts in one
transaction, and both together need more than EIP-7825's 2^24 gas, so they launch separately. The factory makes no initialization calls; the team wallet then
performs the setup described below before minting. The collection and its swapper land at addresses fixed in advance
that start `0x6900`.

| | where it lands on Ethereum |
|---|---|
| Worker Frens, the collection (ERC-721, 2222 frens) | `0x6900d042460d6bdbe68CE994F4dE36706797CCd4` |
| FrenSwapper, the floor's buys | `0x69002297DD7980af0d24249f6a44E7046B1Cb1fb` (or the launch's own: `PlaceModules.swapper()`, see below) |
| FrenMinter, minting with ETH | `0x46B50a3061Ea692e075231c13bc653FdD1Bedd29` |
| FrenWorkerGate, the workers' and WL's window | `0xF83807Ec2E27e1771Fb2594139c1F6925Cfd9B8E` |
| FrenPrices, the price curve as code | `0x8f135B75Df156e6346c8525E138bC2BD652146ff` |
| WorkerFrensRenderer, the art | `0x0a2e5e0c1d00fe63ab4e391c052a023cc7a16292` (LIVE: IMD launch 1067, with WorkerArt1 `0x048f…ef9f` and WorkerArt2 `0x1e3a…0758`) |

The addresses moved from the plan's first version when the launch review's fixes changed the collection's, the swapper's and
the gate's code (`ADAPTATION.md` lists them); the price table's didn't change.

## The collection

- **Name.** The collection is named Worker Frens, symbol wFREN, and each token is "Worker Fren #N".
- **The art, all on chain.** `WorkerFrensRenderer` draws each fren as an 84x84 8-bit bitmap inside an SVG: its
  background through a window its seed picks, then its face, coat, hat and held item. It reads nine data contracts,
  and checks each one's code hash on every read:
  - the IMD swarm's seven FrenArtChunk contracts, already on Ethereum: each character's 13 faces, the 2 hats and 14 of
    the 15 items, as the artist drew them;
  - `WorkerArt1` and `WorkerArt2`, which the separate art launch deploys: the artist's lab coat (3 coats x 6 shirts), the redrawn
    item06, 12 backgrounds and the palettes. The backgrounds are Clean Lab and Messy Lab in blue, green and red, Tube
    in blue, green, red and yellow, and Wireframe in green and red.

  The 12 backgrounds carry more colours than one 256-colour bitmap palette holds, so the palette is split. Indices
  1-145 are the shared colours, the same for every fren. 146-255 are the fren's background's own: each background
  carries its own palette for that range.
  - An unrevealed fren shows a greyed-out card that flicks through random frens in front of the green tube.
  - `script/art/` holds the art as packed (`data/`, from the art kit's `export_v3.py`) and `chunks.py`, which writes
    `src/art/`.
- **The workers' and WL's window.** Once the mint opens, the next 420 frens (the cheapest left on the curve) go only to
  wallets holding window credits:
  - identity.md holders get one credit per NFT (`claim`);
  - wallets on the owner's WL get the amount listed for them (`claimWl(amount, proof, to)`).

  The WL is a Merkle root over `keccak256(bytes.concat(keccak256(abi.encode(wallet, amount))))`, OpenZeppelin's
  standard tree. The owner sets it (`setWlRoot`) and can replace it at any time. A wallet whose amount goes up later
  claims the difference. The window closes when 420 are minted or when the owner opens the public mint.
- **Every job is paid by its own mint.** Each mint sets 0.50 $IMD aside for its agents' job. The collection's job payee
  is the relayer's payer wallet, which pays IMD. The keeper then takes the request's 0.50 back from the collection
  through IMD's x402 proxy, before the reveal voucher is signed. A payment IMD never took before its deadline is undone
  when the request's reveal completes (or by anyone, `releaseLapsedJob`, if it lapses after), and its 0.50 feeds the floor.
- **The floor.** Every fren out in the world owns an equal share of the floor (the IMD6900 reserve and the $IMD waiting
  to be bought into it); `recycle` sells a fren to the treasury for its share, `buyTreasury` buys one back at twice it.
  Once at least one fren is out, the mint price counts the reserve, waiting and unswept $IMD, and pending ETH/WETH.
  This is not an unconditional floor guarantee: pending ETH uses POOL4's manipulable spot price, and removing the
  swapper makes the reserve count as zero (the retained audit findings are in `ADAPTATION.md`). Before that first mint,
  the mandatory bootstrap order below gives the floor
  its first owners before fees or public minting. The last fren out in the world stays out (`LastFrenOut`): with every fren in the treasury the
  floor would have no owner, and whoever minted next would take every fee that arrived meanwhile.

## How the addresses are fixed

IMD deploys a launch from its own deployer, so nothing it creates directly has an address anyone knows in advance. The
launch's two contracts (`src/FrensPlacement.sol`) therefore create everything through the standard CREATE2 deployer
(`0x4e59b44847b379578588920cA78FbF26c0B4956C`, the same on every chain), where an address depends only on a salt and
the exact creation code:

- `src/FrensCode.sol` holds the creation code as data, exactly what forge builds from `src/frens/` with
  `foundry.toml`'s settings.
- `src/FrensPlan.sol` holds the constructor arguments, the mined salts and the addresses they give. The renderer has
  a salt but no planned address, because its constructor takes the art chunks' addresses, which come from IMD's
  deployer.
- These bytes, settings and salts are pinned for this launch. Do not regenerate them: the queued Ethereum timelock
  operation targets the current addresses, and the art depends on exact code hashes.

Anyone can put these exact bytes at these addresses, and the launch takes the contract as it is, with one check: the
swapper's slow price average is seeded from the IMD6900/$IMD pool's price in the block that creates it, so one placed in
a block whose price was pushed would make the frens value their floor off that price. `PlaceModules` takes the swapper
at `0x69002297…` only if its average is the pool's price at the launch (within 2x); otherwise it leaves it there and
creates its own with a plain CREATE (nobody else can put anything at that address), seeded at the launch block's price,
and that one is the frens' swapper: read `PlaceModules.swapper()`, which `setup()` does. The launch itself should go
through a private relay, so nobody can push the price in the launch's own block. On a chain without the CREATE2 deployer
(IMD's fresh-chain run) the launch creates the same contracts with its own CREATE2. The renderer's constructor refuses
anything but the two exact art chunks (`BadArt`): a renderer over other code would draw nothing.

## IMD's audit, fixed (collection job ea109756)

IMD's judge found two money bugs in the collection, and two small ones; all four are fixed here, and the fixes moved the
collection's addresses (re-mined, still `0x6900…`):

- **High: ETH waiting to be bought into the floor (royalties, fees) was left out of the price.** Anyone could mint,
  buy the ETH in, and sell straight back for a share of fees owed to holders. The mint price and the treasury price now
  count that ETH (and WETH) at IMD's ETH pool price (`FrenSwapper.floorValue`). Proven:
  `test_PendingEthCountsInTheMintPrice` fails on the old code (a 0.69 mint where 300 was due) and passes now.
- **Medium: `$IMD` not swept in yet was in the mint price but not in the sale and treasury prices.** `recycle` and
  `buyTreasury` sweep it in first now (`test_UnsweptImdCountsInTheTreasuryPrice`).
- **Low: `approveJob` took a Permit2 nonce already spent**, stranding 0.50 `$IMD`. Refused now
  (`test_KeeperCannotApproveASpentNonce`, `test_Fix_SpentNonceIsRefused`).
- **Low: the script's `open()` / `resume()` could lock themselves out** if the pool moved 2x while floor buys were
  paused. They warn instead now; `setup()` stays strict (`test_OpenAndResumeWarnWhenAverageLags`).
- To keep the collection under EIP-170 with the fixes, `lowerMinTier` (a governance knob, unused) is gone: 24,441 of
  24,576 bytes.
- Mined salts carry no `f2`/`f4`/`ff` byte (gen.py), so a salt the compiler keeps as raw data can't trip the admission scan.

The follow-up audit reproduces four remaining MEDIUM/LOW contract findings: pending ETH valued at spot, dust pinning
the swapper average, duplicate pending Permit2 nonces, and reserve underpricing if the governor removes the swapper.
These remain unchanged by the requester's address-preservation decision. `ADAPTATION.md` records the evidence and
limits; passing `test_Risk_...` tests demonstrate those risks still exist.

## The launches (`evm_contracts`, Ethereum, chain id 1)

The collection is this assignment's launch. The independent art launch has already landed (IMD launch 1067,
renderer `0x0a2e5e0c1d00fe63ab4e391c052a023cc7a16292`):

- **The collection** (about 12.45M gas, all in):
  1. `PlaceFrens` (no constructor arguments): the price table and the collection, for the team wallet
     `0x35dA9C0303507ddf708E87F2568EdDf12c47a059` (owner and governor).
  2. `PlaceModules`, with one argument, `$contract:PlaceFrens`: the swapper, the ETH minter and the gate.
- **The art** (about 13.6M gas, all in):
  1. `WorkerArt1` (no constructor arguments): the first half of the new art, as its code.
  2. `WorkerArt2` (no constructor arguments): the second half.
  3. `WorkerFrensRenderer`, with two arguments, `$contract:WorkerArt1`, `$contract:WorkerArt2`.

## After the launch (the team wallet)

1. Read the confirmed collection launch's `PlaceModules` address. `MODULES` is required; missing or invalid values
   fail, and individual `FRENS`, `SWAPPER`, `MINTER`, `GATE` environment values cannot override its getters. In a block
   after deployment, check `rateAverage()` against `spotRate()` and an independently observed normal pool price.
   Use a private relay for the collection launch; the constructor cannot detect manipulation of its own block's price.
   `setup()` points the collection at the art launch's renderer, wires the reported swapper and gate, then sets and
   seals the trait rules. It pauses floor buys (`setParams(_, 0, 0)`) whenever no fren is minted or the collection is
   not yet an IMD6900 distributor. It also refuses an average outside the existing 2x spot band. This check is a
   sanity check, not an independent oracle.
   `MODULES=<PlaceModules> RENDERER=<WorkerFrensRenderer> forge script script/frens/DeployFrens.s.sol --sig "setup()" --rpc-url … --account imdstr-deployer --broadcast`
2. **Mandatory before moving hook fees, resuming buys, or opening any mint window:** call
   `firstFrens(frens, minter, count, ethIn)` in that script, with the confirmed collection and minter, a positive
   team-selected count and sufficient ETH. This mints to the existing IMD6900 strategy while the public mint is
   closed and buys are paused. Verify `balanceOf(IMD6900) > 0` and `totalMinted() > inTreasury()`. Do not route fees
   or royalties here before this step. Unsolicited transfers cannot be prevented; if they already arrived, the
   strategy must still receive the first frens before anyone else can mint. The pinned contract permits the governor
   to bypass this order; the script guards do not remove that authority.
3. Set the WL: `gate.setWlRoot(root)`. The script's `open()` starts the workers' and WL's window and refuses an empty
   floor. It may run now with buys paused, or after the next step. Do not bypass it with an early `setMintOpen(true)`.
4. Execute the Ethereum timelock batch (`script/frens/FrensTimelockBatch.s.sol`) only after step 2. Check
   `PlaceModules.swapper() == FrensPlan.SWAPPER_AT` before relying on the already queued batch. If the launch replaced
   the swapper, queue and execute the fee exemption for the **actual** swapper; the existing batch's exemption is
   insufficient. Verify distributor status and `PAIR_HOOK.feeExempt(actualSwapper)`, then run `resume()` with the
   same `MODULES`. It verifies both, the wiring and the first frens, and warns if the price average is outside the
   2x spot band before restoring the defaults
   (50 $IMD and 0.25 ETH a buy, one buy a block).
5. The gate's `openPublic()` ends the workers' window early. The optional `handover(frens)` moves governorship to the
   timelock after setup and activation; ownership stays with the team wallet.

If the launch's own swapper was seeded at a pushed price, leave minting closed and buys paused. The governor can
deploy the unchanged `FrenSwapper` with FrensPlan's pool/token/hook arguments and the confirmed collection address in
a normal-price block, validate its average, and call `setModules(newSwapper, existingGate)`. Queue its fee exemption
and wait for execution before restoring buys. This is a manual recovery: the normal script deliberately refuses
wiring that differs from `PlaceModules`. Do not rerun `setup()` over the recovered wiring. A private relay policy
has not been confirmed by this adaptation.

List the collection for **ETH/WETH settlement only**. The pinned royalty receiver has no arbitrary ERC-20 rescue;
USDC, DAI or other unsupported royalties would be stranded. Directly sent IMD6900 is not booked as reserve. Existing
$IMD receipts do have the floor's sweep path.

The keeper must allocate Permit2 nonces persistently per chain and collection, including across restarts and pending
jobs. Before every `approveJob`, read `nonceBitmap(frens, nonce >> 8)` and require
`bitmap & (1 << (nonce & 255)) == 0`; never reuse a nonce already assigned to another pending job. The collection
rejects spent nonces, but accepts duplicate pending nonces: settling one can strand the other's 0.50 $IMD allowance.
Persistent unique allocation remains necessary; no keeper implementation was supplied here to patch.

Keep a valid swapper wired while a reserve exists. For replacement, close minting before changing modules and wire
the replacement directly; do not leave an open mint with `swapper == address(0)`. This operator precaution does not
remove the governor's authority to bypass it. Pending ETH/WETH and a dust-pinned average remain price risks even
with the intended wiring; the setup script's pair-price band does not protect POOL4's spot valuation.

## Tests

`forge test` runs offline; the fork tests run with `MAINNET_RPC_URL`.

- `test/FrensLaunchReview.t.sol`: the protected factory's CREATE2 deployment pattern, the team wallet's roles, a trace
  of the fresh-chain constructor calls, and the audit's and the review's findings against the exact placed collection:
  the fixed ones asserted fixed (the last fren out stays out, a lapsed job payment is released, the launch replaces a
  swapper seeded off a pushed price and refuses the wrong art), the trust assumptions that stay asserted as they are
  (the transfer validator, the governor closing the mint). `ADAPTATION.md` lists each.
- `test/FrensPlacement.t.sol`:
  - the code is the sources' own, and the plan follows from it;
  - the addresses are the same whoever deploys, and the launch deploys on a fresh chain;
  - each launch fits one transaction whole, with 1M to spare (`test_EachLaunchFitsOneTransaction`): its creations,
    its calldata at EIP-7623's rates, and IMD's launcher on top (300,000 + 7 gas a byte, above what two earlier
    launches through it cost). Every initcode is within EIP-3860:

    | launch | contracts (initcode) | gas, all in |
    |---|---|---|
    | the collection | PlaceFrens (40.8 KB), PlaceModules | 12.45M |
    | the art | WorkerArt1 (28.5 KB), WorkerArt2 (21.9 KB), WorkerFrensRenderer (17.4 KB) | 13.6M |
  - IMD's admission scan is clean for every contract. The art chunks are framed (a PUSH32 byte before every 32 bytes),
    and the renderer keeps its index and code hashes as hex text;
  - every new art entry reads back as exactly `script/art/data`'s bytes, and other code at a chunk's address draws
    nothing;
  - on a mainnet fork:
    - the renderer draws exactly the art kit's reference renders (`script/art/data/expected.json`): seven frens across
      the background kinds and three unrevealed cards, byte for byte;
    - a revealed fren's `tokenURI` reads for about 4M gas, an unrevealed one's for about 13M (under 2^24);
    - the whole road: setup (the floor's buys paused), the first frens with ETH, the opening, an ETH mint, two reveals,
      the floor in $IMD, the timelock batch, `resume()`, the floor in IMD6900, the handover. The metadata reads
      "Worker Fren #N" and says nothing of IMD.
- `test/frens/FrenWorkerGate.t.sol`: the workers' credits, and the WL (listed amounts, once, raised amounts, owner-only
  root, the shared 420, never more than 420).
- `test/frens/FrenSwapperAverage.t.sol`: the swapper's slow average moves a full step for a full buy, next to nothing
  for dust.
- `test/FrensResidualRisks.t.sol`: passing reproductions of the four retained MEDIUM/LOW findings using the pinned
  collection and swapper code, plus an averaging probe. They assert the vulnerable behavior, not its repair.
- `python3 test/test_collection_manifest.py`: checks the two factory entries, current addresses across the plan,
  generated address file and handoff documents, the live renderer, and salt bytes against the admission restriction.
- `test/frens/`: the collection's own tests (minting, tiers, reveals, the floor, the last fren out, unswept $IMD, lapsed
  job payments, Permit2 and x402 payments, the transfer validator).

Every library is vendored under `lib/` (only the files imported), so it builds offline: see `lib/README.md`.
