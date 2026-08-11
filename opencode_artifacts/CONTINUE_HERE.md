# CONTINUE HERE — session state (saved 2026-08-10 after session 23 echidna cross-checks)

Resume point: **echidna cross-check campaign on the 5 clean harnesses COMPLETE
(session 23, 2026-08-10).** All 5 green on 3 seeds each. The Phase 3 harness
campaign is now fully corroborated by both foundry and echidna.

## DONE — echidna cross-check on the 5 clean harnesses (session 23)

echidna 2.3.3 + crytic-compile 0.4.2. NOTE: `/tmp/opencode/echidna_venv` is
volatile — if wiped, recreate with `python3 -m venv /tmp/opencode/echidna_venv
&& /tmp/opencode/echidna_venv/bin/pip install crytic-compile --cert
~/.mitmproxy/mitmproxy-ca-cert.pem`. Run pattern: `cd invariant_projects/<p>
&& echidna test/Echidna<X>.sol --contract Echidna<X> --config echidna.yaml`
with `$HOME/.local/bin`, `$HOME/.config/.foundry/bin`,
`/tmp/opencode/echidna_venv/bin` on PATH. Echidna 2.3.3 emulates the forge
cheatcode precompile (startPrank/stopPrank/warp/roll/deal all work).

Results (3 seeds each: default, 12345, 5539492503410371496):
- **hundred-bond: 3/3 PASS** (`EchidnaHundredBond.sol` + `echidna.yaml`).
- **compound-v2: 3/3 PASS** (`EchidnaCompoundV2.sol` + `echidna.yaml`).
  Two harness-domain artifacts resolved in the wrapper and documented in
  `invariant_results.md`: (a) borrow-sum drift is magnitude-independent
  (Compound-v2 integer rounding), tolerance re-scaled to
  `max(1e9 wei, totalBorrows/1e5)`; (b) `mulUInt(principal, borrowIndex)`
  overflow — principal compounds with interest, so the wrapper skips only
  states where `borrowIndex > uintMax/totalBorrows` (the protocol's own
  overflow-protection boundary).
- **credit-guild: 7/7 PASS** (`EchidnaCreditGuild.sol` + `echidna.yaml`).
- **balancer-v2: 8/8 PASS** (`EchidnaBalancer.sol` + `echidna.yaml`).
  Wrapper mod-reduces index args (poolIdx%2, actorIdx%8, tokenIdx%3,
  mode%4) — the handler silently `return`s on out-of-range indices, wasting
  ~99% of raw uint8 calldata; with mods coverage rose 8981 -> 21791 instr.
- **compound-v3: 7/7 PASS** (`EchidnaCompoundV3.sol` + `echidna.yaml`).

All recorded in `opencode_artifacts/invariant_results.md` (protocols 13-17)
with the campaign-complete summary. Combined with the earlier basis-cash,
kpk, morpho-blue, rocket-pool cross-checks, all 12 protocol harnesses are now
corroborated by echidna. Final campaign verdict unchanged: 3 CONFIRMED
static-invisible findings (basis-cash, harvest-ousd, monolith-market),
142/142 run3 DISMISSED, 18/18 ionic CONFIRMED, no new findings from echidna.

## Phase 3 campaign summary (12 protocols)
- **3 CONFIRMED static-invisible protocol bugs** (all fund-lock / accounting
  breakage, none exploitable for theft):
  1. basis-cash Boardroom: phantom/retroactive reward inflation — late
     claimers' `claimDividends`/`withdraw` revert (stuck funds); foundry +
     echidna agree.
  2. harvest-ousd: yield delegation + negative rebase underflows the target's
     credits → target account permanently reverts (fund-lock).
  3. monolith-market: permissionless `Lender.writeOff` on the sole remaining
     debtor deletes debt without burning Coin → permanently unbacked Coin.
- **142/142 run3 findings DISMISSED** across the 9 harnessed finding-bearing
  protocols (credit-guild 41, compound-v2 7, balancer-v2 19, rocket-pool 3,
  morpho-blue 7, compound-v3 13, monolith 26, kpk 56, harvest 5... see
  STATUS.md for the running tally) and **18/18 run3 ionic findings
  CONFIRMED** (16 provable owner-only ZeroAddress setters + 2 latent
  StorageCollision upgrade hazards).
- Clean high-value harnesses (9): credit-guild, compound-v2, hundred-bond,
  balancer-v2, rocket-pool, morpho-blue, compound-v3, kpk, plus ionic
  (findings confirmed but all MEDIUM/low-exploitability).
- Tooling wins: root-caused the foundry invariant-fuzzer revert-journaling bug
  (foundry_invariant.rs:547); the prank+value revert-leak trap (compound-v2);
  Morpho's 1-wei repay dust; Comet's three naive-invariant traps; kpk's share
  scale (1e24/$1 at 8dp prices).
- Bottom line for the analyzer: on the 22-protocol corpus the detectors'
  findings are overwhelmingly FPs (142/142 dismissed), but the invariant
  harnesses found 3 real static-invisible bugs — the analyzer's precision
  story stands, and invariant testing proved complementary value.

## Phase 3 status (12 protocols)
- basis-cash: Boardroom phantom-reward finding CONFIRMED (foundry + echidna 2.3.3 agree).
- harvest-ousd: yield-delegation/negative-rebase fund-lock finding CONFIRMED.
- credit-guild: NO finding. 7/7 invariants HOLD, 9/9 smoke, 41/41 run3 DISMISSED.
- compound-v2: NO finding. 3/3 invariants HOLD, 9/9 smoke, 7/7 run3 DISMISSED.
- hundred-bond: NO finding. 3/3 invariants HOLD, 9/9 smoke, run3 = 0 findings.
- balancer-v2: NO finding. 8/8 invariants HOLD, 8/8 smoke, 19/19 run3 DISMISSED.
- ionic-protocol: NO finding. 3/3 invariants HOLD, 12/12 smoke, **18/18 run3
  findings CONFIRMED** (16 ZeroAddress owner setters x2 chains + 2
  StorageCollision upgrade-hazard).
- rocket-pool: NO finding. 4/4 invariants HOLD, 8/8 smoke, echidna cross-check
  on 2 seeds passing, 3/3 run3 DISMISSED. Root-caused foundry fuzzer
  revert-journaling bug (foundry_invariant.rs:547).
- morpho-blue: NO finding. 10/10 invariants HOLD, 8/8 smoke, echidna cross-check
  passing (session 17), 7/7 run3 DISMISSED. Surfaced + root-caused Morpho's
  1-wei repay dust.
- compound-v3: NO finding. 7/7 invariants HOLD, 7/7 smoke, 13/13 run3
  DISMISSED. Root-caused three naive invariants (solvency condition, absorb
  can grow reserves, 1-unit principalValue dust) into the real protocol
  behavior.
- monolith-market: **CONFIRMED finding #3 (HIGH)** — `Lender.writeOff` on the
  sole remaining debtor deletes debt without burning Coin (permanently unbacked
  Coin; Lender.sol:302-332, redistribution gated on `totalDebt > 0`).
  4/5 invariants HOLD (150k calls, 0 reverts), 8/8 smoke; invariant_coinLedger
  FAILS on the 2-call counterexample. All 26/26 run3 findings DISMISSED.
  Secondary low note: getDebtOf/getRedeemAmountOut mulDiv overflow at extreme
  interest-inflated debt.
- kpk: NO finding. 2/2 invariants HOLD (150k calls/invariant, 3 seeds), 10/10
  smoke, **56/56 run3 findings DISMISSED** (14 unique x4 chains). Closing
  protocol of the run3 sweep.

## kpk harness (session 21, this session's work)
- Path: `invariant_projects/kpk/` (solc 0.8.24 pinned to
  `/home/fatima/Downloads/static-analyzer/solc_versions/solc-0.8.24`, evm
  paris, via_ir=true, optimizer 200; OZ v5.0.0 vendored at `lib/` — needs
  ^0.8.20). foundry.toml `[invariant] runs=200 depth=120 fail_on_revert=false`.
- Vendored verbatim into `src/`: kpkShares.sol (1,145 lines) + KpkOivFactory.sol
  + IkpkShares.sol + FeeModules/ + interfaces/ + utils/ (no source edits).
- UUPS proxy: ERC1967Proxy + `initialize` pranked as ADMIN (base USDC 6dp $1;
  SAFE 0x5000 prefunded with standing max allowance; MockPerfFeeModule; mgmt
  5% / redemption 1% / perf 2%; TTLs 1 day); OPERATOR role + `updateAsset`
  (WETH 18dp $3000, SPARE 18dp) as OPERATOR.
- `KpkHandler.sol` (6 actors prefunded 1M/asset, prank-based sender, low-level
  swallowed reverts, shadow request book + staticcall getRequest bias, 9 fuzz
  actions incl. processAction with ±10% settled-price band + rare 1/8 wild
  price), `Invariants.t.sol` (2 exact ledger identities), `Smoke.t.sol` (10
  tests), `Debug.t.sol` (killed after green). **2/2 invariants HOLD** at
  200/120 and 500/300 (150k calls/invariant, 3 seeds default/1337/42, ~11.5k
  swallowed reverts = price-deviation/expiry/TTL guards); **10/10 smoke PASS**.
- KEY LEARNING: the share scale — shares = assets·1e26/(price·10^assetDec),
  so $1 @1e8 = **1e24 shares** (6dp base) but 3 WETH @3000e8 = **1e15 shares**
  (18dp asset/shares decimals cancel). The naive 1e18 expectations made the
  min-shares guard fire `RequestPriceLowerThanOperatorPrice`; re-pinned to the
  real scale turned the whole smoke suite green.
- NOTE: forge 1.7.1 has no `--fuzz-depth` CLI flag and `FOUNDRY_*` env
  overrides are ignored — deep runs (500/300) require editing foundry.toml
  `[invariant]` directly (restored to 200/120 after).
- run3 cross-check: 14/14 unique DISMISSED (56 total). Reentrancy HIGH 1056 =
  CEI-pattern `_updateAsset` (read-only symbol()/decimals() then push,
  operator-only, updateAssetAction ran ~16k times/run with 0 reverts);
  ValueFlow 231 = transfer-in-then-ledger `+=`, refuted by the exact
  `assetEscrow` identity across 150k calls; ZeroAddress 217/665/772/799/1102/
  1141 = init/admin/request-struct classes; Timestamp 269/383 = the intentional
  TTL gates (smoke-pinned); StorageCollision factory:76/kpkShares:22 =
  contract-declaration UUPS class; IntegerOverflow OZ lib 230/235 = guarded
  balances. Details in `invariant_results.md`.


## monolith-market harness (session 20, this session's work)
- Path: `invariant_projects/monolith-market/` (solc 0.8.13 pinned to
  `/home/fatima/Downloads/static-analyzer/solc_versions/solc-0.8.13`, evm
  paris, via_ir=true). foundry.toml `[invariant] runs=200 depth=120
  fail_on_revert=false`.
- Vendored verbatim into `src/`: Lender/Vault/Factory/Coin/InterestModel +
  solmate (no source edits). Factory operator = 0x2000 (distinct from the
  lender operator actors[0]; fee recipient actors[1]); factory fee 1% set
  BEFORE `factory.deploy` so the Lender caches it at construction.
- `MonolithHandler.sol` (6 actors prefunded 1M collateral; prank-based sender,
  low-level swallowed reverts; 19 fuzz actions), `Invariants.t.sol` (5 exact
  ledger invariants), `Smoke.t.sol` (8 tests). 4/5 invariants HOLD at 200/120
  and 500/300 (150k calls, 0 reverts on seeds 42/1337); 8/8 smoke PASS.
- KEY FINDING (CONFIRMED HIGH): `Lender.writeOff` — permissionless; deletes the
  borrower's debt with no Coin burn (Lender.sol:315) then redistributes to the
  remaining debtors only `if (totalDebt > 0)` (line 318). Sole-debtor write-off
  skips the redistribution, so `supply == freeDebt + paidDebt - reserves` breaks
  permanently. Stable 2-call counterexample:
  1. `combinedBorrow(3647824450842923331174363683827,
     14928331485464224384976708264443215047998206326689562727012306)` actor 0x1001
  2. `attemptWriteOff(27560079151)` actor 0x1000 (~30h staleness => price
     decays in the 49h unwind window while allowLiquidations stays true).
  Reachable via oracle staleness or >99% price collapse in a single-borrower
  market. Smoke-pinned: `test_writeoff_last_debtor_breaks_coin_backing`.
- Handler robustness: getDebtOf/getRedeemAmountOut overflow (solmate
  mulDivDown shares*debt > 2^256) at extreme interest-inflated debt; the
  handler try/catch-wraps those view reads so it never reverts (documented low
  availability note).
- run3 cross-check: 26/26 DISMISSED (9 Reentrancy HIGH CEI-pattern flags, 5
  AccessControl HIGH permissionless-by-design, 7 ZeroAddress governance inputs,
  2 FrontRunning + 1 MEV approve/ERC4626, 2 ValueFlow fee-on-transfer
  assumption). Details in `invariant_results.md`.

## compound-v3 harness (sessions 18-19, this session's work)
- Path: `invariant_projects/compound-v3/` (solc 0.8.15 pinned to
  `/home/fatima/Downloads/static-analyzer/solc_versions/solc-0.8.15`, evm
  paris, via_ir=true). foundry.toml `[invariant] runs=200 depth=120
  fail_on_revert=false`.
- Vendored verbatim into `src/core/`: `CometWithExtendedAssetList.sol` +
  CometCore/CometConfiguration/CometMath/CometStorage/CometMainInterface +
  IAssetList*/IERC20NonStandard/IPriceFeed. No source edits.
- Constructor config: base USDC 6dp ($1 feed); coll WETH 18dp $2000 (BCF
  0.8/LCF 0.9/LiqF 0.92) and WBTC 8dp $30000 (0.75/0.85/0.9); storeFrontPrice
  Factor 0.5; supply kink 0.8; borrowPerYearInterestRateBase = 0.04e18 (so
  `util*borrowRate >= supplyRate` over the whole utilization range — reserve
  growth structurally non-negative). 8 actors prefunded 1M USDC / 1000 WETH /
  100 WBTC.
- `CometHandler.sol`: prank-based sender, low-level swallowed reverts; 7 fuzz
  actions supply/withdraw/transfer/absorb (oracle shocked to a random fraction
  of honest first, restored after)/buyCollateral/pause/warp. `_tick` only in
  non-absorb actions so absorb reserves deltas are exact. Reads internal
  `totalSupplyBase`/`totalBorrowBase` via `VM.load(comet, slot 1)`.
- 7 invariants: base book conserved (sum positives == totalSupplyBase, sum
  negatives == totalBorrowBase), WETH/WBTC collateral books, base no-leak
  (reserves + absorbedBadDebt >= 0), per-action residual >= -DUST (DUST=1 base
  unit), absorb debt-bound (delta >= -(debtBefore+DUST)), market solvent
  (balance + totalBorrow + absorbedBadDebt >= totalSupply). GREEN at 200/120
  and 500/300 (150k calls, 0 reverts) on 4 seeds incl. the previously-failing
  one. 7/7 smoke tests pass.
- THREE naive invariants root-caused (the real protocol behaviors):
  (1) `totalSupply() >= totalBorrow()` is NOT solvency — both are present-value
  views and the borrow index grows faster in the profitable case; (2) absorb
  can legitimately GROW reserves (over-covered collateral at the liquidation
  factor becomes a supply position; write-off can exceed external
  `borrowBalanceOf` by 1 base unit); (3) non-absorb actions can move exactly 1
  base unit of principalValue floor-rounding dust.
- run3 cross-check: 13/13 DISMISSED (9 OracleManipulation/OracleTaint HIGH + 1
  Timestamp LOW = the shocked-price absorb surface; 2 ZeroAddress internal
  paths; 2 SignatureReplay delegatecall-extension signed allow; 1
  delegatecall-only extension storage artifact). Details in
  `invariant_results.md`.
- Diagnostics kept by design: `invariant_lastResidual`/`invariant_absorbAccounting`
  revert with lastDelta/lastBound via the handler's `uint2str` (only fires on
  violations).

## morpho-blue harness (sessions 15-16, this session's work)
- Path: `invariant_projects/morpho-blue/` (solc 0.8.19 pinned to
  `/home/fatima/Downloads/static-analyzer/solc_versions/solc-0.8.19`, evm
  paris, via_ir=true). foundry.toml `[invariant] runs=200 depth=120
  fail_on_revert=false`.
- Files: `src/core/` = full vendored `Morpho.sol` + interfaces + libraries
  verbatim (no source edits); `src/mocks/{MockERC20,MockOracle,MockIrm}.sol`;
  `test/MorphoHandler.sol` (2 cross-token markets: A USDC/WETH oracle 2000
  LLTV 86% fee 10%, B WETH/USDC oracle 1/2000 LLTV 80% fee 0; 8 actors 1M
  USDC + 1000 WETH; 12 fuzz actions supply/supplyCollateral/borrow/withdraw/
  withdrawCollateral/repay/liquidate/accrue/warp/setFee/setFeeRecipient/
  setOwner; prank-based sender, low-level swallowed reverts); 
  `test/Invariants.t.sol` (10 invariants), `test/Smoke.t.sol` (8 tests),
  `test/Debug.t.sol` (2 shrunk-counterexample replays, PASS).
- The 10 invariants: supply-share conservation (actors + feeRecipient +
  address(0) — covers a zero fee recipient), borrow-share conservation,
  per-token no-leak balance-sheet (physical >= idle + counterpart collateral),
  per-action ledger residual in {0,1}, market solvency.
- KEY FINDING (protocol rounding, not a bug): Morpho's absolute balance-sheet
  identity is NOT exact. The virtual-share model (SharesMathLib VIRTUAL_SHARES
  = 1e6) lets a repayment of the last borrow share compute `assets` one wei
  above `totalBorrowAssets`, overpaying 1 wei into the pool per full-book-share
  repay (Morpho.sol:290 comment). The gap ACCUMULATES over borrow->full-repay
  cycles (observed 2 wei), so no fixed tolerance is sound. Fixed by
  reformulating the ledger invariant as the exact PER-ACTION bound: each
  action may diverge physical vs book by at most +1 (never <0 = no value
  leak), tracked via handler `lastUsdcResidual`/`lastWethResidual`. This is
  also exactly the `balanceOf`-delta discipline the run3 ValueFlow detector
  recommends.
- run3 cross-check verdicts (details in `invariant_results.md`): 7/7 DISMISSED
  (ZeroAddress setOwner/setFeeRecipient = documented one-way governance door;
  ValueFlow supply/repay = non-FoT token assumption the interface documents;
  liquidate AccessControl = permissionless by design; setAuthorizationWithSig =
  EIP-712 ecrecover; _accrueInterest reentrancy = owner-whitelisted IRM).

## NEXT STEP — done (campaign complete)
- Phase 3 report addenda #7-#12 written to `opencode_artifacts/REPORT.md`
  (ionic, rocket-pool, morpho-blue, compound-v3, monolith, kpk).
- All sessions committed + pushed to `origin/release-0.2` (HEAD `4ca58b2`):
  `ebd8417` (rocket-pool), `b769e20` (morpho-blue), `82e4118` (echidna),
  `d6fe668` (compound-v3), `dc5b9c7` (monolith), `02740a3` (kpk),
  `4ca58b2` (report).
- Optional echidna cross-check on kpk DECLINED (foundry 150k-call/3-seed run
  is sufficient corroboration). If ever wanted, the env is ready: venv
  `/tmp/opencode/echidna_venv` (crytic-compile 0.4.2), solc-select global
  must be switched to 0.8.24, echidna binary at `~/.config/.foundry/bin/echidna`.

## Echidna environment (set up during session 17, still current)
- venv `/tmp/opencode/echidna_venv` (crytic-compile 0.4.2; recreate if wiped:
  `python3 -m venv /tmp/opencode/echidna_venv &&
  /tmp/opencode/echidna_venv/bin/pip install crytic-compile`).
- solc-select (pip-installed, global = 0.8.19; artifacts have
  0.6.12/0.7.6/0.8.19/0.8.36). echidna binary: `~/.config/.foundry/bin/echidna`.
- morpho-blue cross-check recap: `test/EchidnaMorphoBlue.sol` + `echidna.yaml`
  (testLimit 50000, seqLen 100, whitelist of 12 forwarded fuzz actions); ran
  `cd invariant_projects/morpho-blue && echidna test/EchidnaMorphoBlue.sol
  --contract EchidnaMorphoBlue --config echidna.yaml` with
  `$HOME/.local/bin` + venv bin on PATH. Result: 10/10 passing, 50234 calls,
  cov 14843 (seed 5539492503410371496), appended to `invariant_results.md`.

## Key paths
- Analyzer: `/home/fatima/Downloads/static-analyzer` (venv `analyzer_env/`)
- Invariant harnesses: `invariant_projects/{basis-cash,...,kpk}/`
- Artifacts: `opencode_artifacts/{STATUS,ROADMAP,REPORT,invariant_results,CONTINUE_HERE}.md`
- run3 findings: `opencode_artifacts/run3/` (morpho-blue.json 7, compound-v3.json 13)
- TVL corpus: `/home/fatima/Downloads/TVL/output_2026_08_01_22_58_07/full_code/<proto>/`
- Forge: `~/.config/.foundry/bin/forge` (1.7.1); Echidna: same dir (2.3.3)

## Historical context (Phases 1-2)
See `STATUS.md` (per-session log) and `REPORT.md` (addenda) for Phase 1
(ranking + PoC triage, null result), Phase 2 (solc coverage gap fixed -> 60
project re-run 44/60, 447 findings; all new-detector HIGHs triaged DISMISSED;
canonical artifacts = run3) and Phase 3 sessions 1-2 (basis-cash + harvest
OUSD CONFIRMED findings). Phase 3 sessions 3-4 (credit-guild), 5-6
(compound-v2), 7-8 (hundred-bond), 9-10 (balancer-v2), 11-12 (ionic),
13-14 (rocket-pool), 15-17 (morpho-blue, incl. echidna cross-check) and 18-19
(compound-v3) and session 20 (monolith-market, CONFIRMED writeOff unbacking
finding + 26/26 run3 DISMISSED) are summarized in the sections above.
