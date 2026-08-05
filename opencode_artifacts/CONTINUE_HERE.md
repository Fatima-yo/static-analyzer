# CONTINUE HERE — session state (saved 2026-08-05 ~after Phase 3 morpho-blue)

Resume point: Phase 3 protocol 9 (morpho-blue) is COMPLETE and COMMITTED
(ebd8417..morpho-blue commit). The Morpho lending-ledger harness is GREEN
(10/10 invariants at 200/120 and 500/300, 150k calls, 0 reverts; 8/8 smoke
tests); all 7 run3 morpho-blue findings DISMISSED. The **echidna 2.3.3
cross-check over the morpho-blue harness is IN PROGRESS** — the venv was
recreated (crytic-compile 0.4.2 installed), but the `EchidnaMorphoBlue.sol`
wrapper, `echidna.yaml`, and solc 0.8.19 wiring are NOT yet done, and no
echidna run has happened.

## Phase 3 status (9 protocols)
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
- morpho-blue: NO finding. 10/10 invariants HOLD, 8/8 smoke, 7/7 run3
  DISMISSED. Surfaced + root-caused Morpho's 1-wei repay dust (see below).

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

## NEXT STEP (echidna 2.3.3 cross-check over morpho-blue) — partially set up
1. `test/EchidnaMorphoBlue.sol` — composition wrapper over `MorphoHandler`
   forwarding the 12 fuzz actions + `echidna_*` properties (mirror
   `invariant_projects/rocket-pool/test/EchidnaRocketPool.sol`).
2. `echidna.yaml` — `testMode: property`, `testLimit: 50000`, `seqLen: 100`,
   `filterBlacklist: false`, whitelist the 12 wrapper action fns.
3. Environment (venv was wiped with /tmp on reboot — recreated this session):
   - venv: `/tmp/opencode/echidna_venv` with crytic-compile 0.4.2 INSTALLED
     (recreate if wiped: `python3 -m venv /tmp/opencode/echidna_venv &&
     /tmp/opencode/echidna_venv/bin/pip install crytic-compile`).
   - `~/.solc-select/artifacts/` currently has solc-0.6.12/0.7.6/0.8.36;
     **needs solc-0.8.19** (copy from
     `/home/fatima/Downloads/static-analyzer/solc_versions/solc-0.8.19` and
     set global version) to match the project solc pin.
   - echidna binary: `~/.config/.foundry/bin/echidna` (2.3.3).
   - NOTE: the handler uses `vm.warp` via the forge cheatcode address; echidna
     honors warp/prank/startPrank (verified in the rocket-pool session).
4. Run with the venv's crytic-compile on PATH + solc-select global 0.8.19:
   `cd invariant_projects/morpho-blue && echidna test/EchidnaMorphoBlue.sol
   --contract EchidnaMorphoBlue --config echidna.yaml` (see the rocket-pool
   session notes for the exact invocation/crytic compile flags).
5. Append the results to `invariant_results.md` + `STATUS.md` and commit.

## Key paths
- Analyzer: `/home/fatima/Downloads/static-analyzer` (venv `analyzer_env/`)
- Invariant harnesses: `invariant_projects/{basis-cash,...,morpho-blue}/`
- Artifacts: `opencode_artifacts/{STATUS,ROADMAP,REPORT,invariant_results,CONTINUE_HERE}.md`
- run3 findings: `opencode_artifacts/run3/` (morpho-blue.json 7)
- TVL corpus: `/home/fatima/Downloads/TVL/output_2026_08_01_22_58_07/full_code/<proto>/`
- Forge: `~/.config/.foundry/bin/forge` (1.7.1); Echidna: same dir (2.3.3)

## Historical context (Phases 1-2)
See `STATUS.md` (per-session log) and `REPORT.md` (addenda) for Phase 1
(ranking + PoC triage, null result), Phase 2 (solc coverage gap fixed -> 60
project re-run 44/60, 447 findings; all new-detector HIGHs triaged DISMISSED;
canonical artifacts = run3) and Phase 3 sessions 1-2 (basis-cash + harvest
OUSD CONFIRMED findings). Phase 3 sessions 3-4 (credit-guild), 5-6
(compound-v2), 7-8 (hundred-bond), 9-10 (balancer-v2), 11-12 (ionic),
13-14 (rocket-pool) and 15-16 (morpho-blue) are summarized in the sections
above.
