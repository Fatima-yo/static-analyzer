# CONTINUE HERE — session state (saved 2026-08-04 ~after Phase 3 credit-guild)

Resume point: Phase 3 protocol 3 (credit-guild) is COMPLETE. The full ECG
lending-loop harness is GREEN (7/7 invariants at 200/1000/1500 runs; 9/9 smoke
tests) and all 41 run3 credit-guild findings are triaged DISMISSED. Committed
on branch `release-0.2` (`git -c user.name="Fatima-yo" -c
user.email="castiglionemaldonado@gmail.com"`). Next = Phase 3 protocol 4 or an
echidna pass over the newer harnesses.

## Phase 3 status (3 protocols)
- basis-cash: Boardroom phantom-reward finding CONFIRMED (foundry + echidna 2.3.3 agree).
- harvest-ousd: yield-delegation/negative-rebase fund-lock finding CONFIRMED.
- credit-guild: NO finding. 7/7 invariants HOLD, 9/9 smoke tests pass, all 41
  run3 findings DISMISSED (details in `invariant_results.md` + `STATUS.md`).

## credit-guild harness (sessions 3-4, this session's work)
- Path: `invariant_projects/credit-guild/` (solc 0.8.13, evm london, optimizer
  runs=200, remappings `@openzeppelin/contracts/=`, `@src/=`). foundry.toml
  restored to defaults after stress runs (`[invariant] runs=200 depth=120
  fail_on_revert=false`).
- Files: `test/CreditGuildHandler.sol` (full wiring: handler = core admin;
  terms + minter hold GAUGE_PNL_NOTIFIER/CREDIT_MINTER/BURNER/
  RATE_LIMITED_CREDIT_MINTER; ProfitManager holds CREDIT_MINTER+BURNER;
  `setMaxGauges(10)`; `setGaugeWeightTolerance(2e18)`; verified bytes.concat
  EIP-1167 clone; `_tick()` = roll+1 + warp+12s), `test/Invariants.t.sol`
  (7 invariants, ALL PASSING), `test/Smoke.t.sol` (9 round-trip tests).
- Key protocol semantics learned (see invariant_results.md): call() sets
  callTime NOT closeTime; partialRepay needs remaining > minBorrow(100e18);
  forgive needs fully-elapsed auction; warpDays caps at 30d/call (%31);
  surplus buffer is a loss-absorber not donor-reclaimable; gaugeWeightTolerance
  120% default dead-caps balanced-gauge 2nd borrows.
- Verification: `forge test` = 16/16 pass (9 smoke + 7 invariants, ~10s);
  invariants also green at `--fuzz-runs 1000` and 1500/200 stress.
- Analyzer untouched: pytest 21 passed, corpus 138/138 unaffected.

## Next steps (Phase 3 continued)
1. 4th protocol harness: balancer-v2 or compound-v2 (compound-v2 CEther
   borrow/repay+liquidate loop is a strong candidate; balancer-v2 has the
   guarded-subtraction FlashLoan path already PoC'd in Phase 1).
2. Optional: echidna 2.3.3 pass over the harvest-ousd and/or credit-guild
   harnesses (both are pure-foundry right now).
3. If a 4th protocol finds nothing, consider widening credit-guild's fuzz
   surface (profitSharingConfig params, partialRepayDelay, multi-term gauges,
   fee-on-transfer collateral) before moving to Phase 4.

## Key paths
- Analyzer: `/home/fatima/Downloads/static-analyzer` (venv `analyzer_env/`)
- Invariant harnesses: `invariant_projects/{basis-cash,harvest-ousd,credit-guild}/`
- Artifacts: `opencode_artifacts/{STATUS,ROADMAP,REPORT,invariant_results,CONTINUE_HERE}.md`
- run3 findings: `opencode_artifacts/run3/credit-guild.json` (41 findings)
- TVL corpus: `/home/fatima/Downloads/TVL/output_2026_08_01_22_58_07/full_code/<proto>/`
- Forge: `~/.config/.foundry/bin/forge` (1.7.1); Echidna: same dir (2.3.3)

## Historical context (Phases 1-2)
See `STATUS.md` (per-session log) and `REPORT.md` (addenda) for Phase 1
(ranking + PoC triage, null result), Phase 2 (solc coverage gap fixed -> 60
project re-run 44/60, 447 findings; all new-detector HIGHs triaged DISMISSED;
canonical artifacts = run3) and Phase 3 sessions 1-2 (basis-cash + harvest
OUSD CONFIRMED findings). Phase 3 session 3-4 (credit-guild) is summarized in
the new sections above.
