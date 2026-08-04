# CONTINUE HERE — session state (saved 2026-08-04 ~after Phase 3 compound-v2)

Resume point: Phase 3 protocol 4 (compound-v2) is COMPLETE. The CEther
money-market harness is GREEN (3/3 invariants at 200 and 1000 runs, 9/9 smoke
tests) and all 7 run3 compound-v2 findings are triaged DISMISSED. The session
also root-caused a foundry prank+value revert leak (fuzz-only 1e24 loss) and
fixed it architecturally with real Actor contracts. Next = Phase 3 protocol 5
or an echidna pass over the newer harnesses.

## Phase 3 status (4 protocols)
- basis-cash: Boardroom phantom-reward finding CONFIRMED (foundry + echidna 2.3.3 agree).
- harvest-ousd: yield-delegation/negative-rebase fund-lock finding CONFIRMED.
- credit-guild: NO finding. 7/7 invariants HOLD, 9/9 smoke tests pass, all 41
  run3 findings DISMISSED (details in `invariant_results.md` + `STATUS.md`).
- compound-v2: NO finding. 3/3 invariants HOLD (ctoken supply exact, ETH
  conservation exact, borrow ledger within 1e9), 9/9 smoke tests pass, all 7
  run3 findings DISMISSED.

## compound-v2 harness (sessions 5-6, this session's work)
- Path: `invariant_projects/compound-v2/` (solc 0.5.8, evm istanbul, optimizer
  runs=200; no remappings needed — the flattened 0.4.x CEther.sol compiles
  as-is with its public constructor). foundry.toml:
  `[invariant] runs=200 depth=120 fail_on_revert=false call_override=false`.
- Files: `src/CEther.sol` (vendored 0.4ddc2d... snapshot),
  `src/SimpleComptroller.sol` (permissive hooks, 1e18 price, 1.08e18 incentive,
  faithful liquidateCalculateSeizeTokens with the exchange-rate guard),
  `src/SimpleInterestRateModel.sol` (White-Paper, never hits the rate cap),
  `test/Actor.sol` (real on-chain users; each owns 1M ETH and calls the markets
  with itself as msg.sender), `test/CompoundV2Handler.sol` (8 actions +
  warpBlocks through the actors; same-market and over-seize liquidations
  skipped; each success rolls the block), `test/Invariants.t.sol` (3
  invariants, ALL PASSING), `test/Smoke.t.sol` (9 round-trip tests).
- **Foundry prank+value revert leak (root cause of the session):** the first
  handler used `vm.startPrank(actor)` + high-level `c.mint.value(x)()`. Under
  the invariant fuzz runner a reverting value call lost exactly one full actor
  balance (1e24): ETH conservation broke to 7e24 with the handler's own
  post-action check never firing (the revert unwound the whole handler call
  before _tick), while every hand-replay of the shrunken counterexample
  (direct / outer-prank / low-level-swallowed-reverts) PASSED. A low-level
  `.call.value()`-from-a-0-balance-handler variant instead silently did nothing
  under fuzz (caught with a temporary step-gated activity invariant). Fix: real
  Actor contracts doing ordinary atomic EVM transfers — no value cheatcodes
  anywhere. After the redesign: conservation green, activity verified, then all
  instrumentation stripped (handler + Invariants.t.sol restored to clean).
- Verification: `forge test` = 12/12 pass (9 smoke + 3 invariants, ~4s);
  invariants also green at invariant runs=1000 (~20s) and `--fuzz-runs 5000`.
- Analyzer untouched: pytest 21 passed, corpus 138/138 unaffected.

## Next steps (Phase 3 continued)
1. 5th protocol harness: balancer-v2 (guarded-subtraction FlashLoan path already
   PoC'd in Phase 1) or another high-value compound-family / lending protocol.
2. Optional: echidna 2.3.3 pass over the credit-guild and/or compound-v2
   harnesses (both are pure-foundry right now).
3. If the next protocol finds nothing, widen a harness surface (multi-market
   collateral combos, interest-only rate models, reserve/claim paths) before
   moving to Phase 4.

## Key paths
- Analyzer: `/home/fatima/Downloads/static-analyzer` (venv `analyzer_env/`)
- Invariant harnesses: `invariant_projects/{basis-cash,harvest-ousd,credit-guild,compound-v2}/`
- Artifacts: `opencode_artifacts/{STATUS,ROADMAP,REPORT,invariant_results,CONTINUE_HERE}.md`
- run3 findings: `opencode_artifacts/run3/` (credit-guild.json 41, compound-v2 7)
- TVL corpus: `/home/fatima/Downloads/TVL/output_2026_08_01_22_58_07/full_code/<proto>/`
- Forge: `~/.config/.foundry/bin/forge` (1.7.1); Echidna: same dir (2.3.3)

## Historical context (Phases 1-2)
See `STATUS.md` (per-session log) and `REPORT.md` (addenda) for Phase 1
(ranking + PoC triage, null result), Phase 2 (solc coverage gap fixed -> 60
project re-run 44/60, 447 findings; all new-detector HIGHs triaged DISMISSED;
canonical artifacts = run3) and Phase 3 sessions 1-2 (basis-cash + harvest
OUSD CONFIRMED findings). Phase 3 sessions 3-4 (credit-guild) and 5-6
(compound-v2) are summarized in the new sections above.
