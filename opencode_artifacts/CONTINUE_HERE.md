# CONTINUE HERE — session state (saved 2026-08-05 ~after Phase 3 compound-v3)

Resume point: Phase 3 protocol 10 (compound-v3) is COMPLETE and COMMITTED
(compound-v3 commit). The Comet lending-market harness is GREEN (7/7
invariants at 200/120 and 500/300, 150k calls, 0 reverts on 4 seeds; 7/7
smoke tests); all 13 run3 compound-v3 findings DISMISSED. Next: the 11th
protocol (see NEXT STEP).

## Phase 3 status (10 protocols)
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

## NEXT STEP (11th protocol) — pick a target from the run3 canonical list
compound-v3 is done. The next session starts protocol 11: pick a remaining
high-value project from
`opencode_artifacts/run3/`, build the same playbook harness
(`invariant_projects/<proto>/`), then document + commit.
Echidna environment for future cross-checks (all set up this session):
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
- Invariant harnesses: `invariant_projects/{basis-cash,...,compound-v3}/`
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
(compound-v3) are summarized in the sections above.
