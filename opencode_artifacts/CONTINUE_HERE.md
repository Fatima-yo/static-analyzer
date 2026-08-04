# CONTINUE HERE — session state (saved 2026-08-04 ~after Phase 3 hundred-bond)

Resume point: Phase 3 protocol 5 (hundred-finance HundredBond) is COMPLETE.
The bond token-accounting harness is GREEN (3/3 invariants at 200 and 1000
runs, 9/9 smoke tests); run3 `hundred-finance.json` has 0 findings so there is
nothing to cross-check. Two design observations surfaced (broken v1 escrow
path; burn pays the owner, not the user). Next = Phase 3 protocol 6 or an
echidna pass over the newer harnesses.

## Phase 3 status (5 protocols)
- basis-cash: Boardroom phantom-reward finding CONFIRMED (foundry + echidna 2.3.3 agree).
- harvest-ousd: yield-delegation/negative-rebase fund-lock finding CONFIRMED.
- credit-guild: NO finding. 7/7 invariants HOLD, 9/9 smoke tests pass, all 41
  run3 findings DISMISSED (details in `invariant_results.md` + `STATUS.md`).
- compound-v2: NO finding. 3/3 invariants HOLD (ctoken supply exact, ETH
  conservation exact, borrow ledger within 1e9), 9/9 smoke tests pass, all 7
  run3 findings DISMISSED.
- hundred-bond: NO finding. 3/3 invariants HOLD (HNDb backing exact, HNDb
  supply exact, HND conservation == 1M ether), 9/9 smoke tests pass, run3
  hundred-finance = 0 findings. Design observations only.

## hundred-bond harness (sessions 7-8, this session's work)
- Path: `invariant_projects/hundred-bond/` (solc 0.8.0, optimizer runs=200,
  remapping `@openzeppelin/contracts/=src/`). foundry.toml:
  `[invariant] runs=200 depth=120 fail_on_revert=false call_override=false`.
- Files: `src/HundredBond.sol` (vendored Polygon 0x636b5b... snapshot, 92
  lines, `escrow_is_v2` flag + `escrow.approve` in the v2 path),
  `src/access|security|token|utils` (OZ 4.4.1 deps), `test/Hnd.sol` (HND,
  1M ether to the handler), `test/MockEscrow.sol` (veCRV-semantics:
  `locked`/`deposit_for`/`create_lock_for` pull from `msg.sender`),
  `test/HundredBondHandler.sol` (handler = bond owner + sole HND holder,
  approves the bond once; 8 actors; ownerMint / actorBurn / actorRedeem /
  warp(200w cap)), `test/Invariants.t.sol` (3 invariants, ALL PASSING),
  `test/Smoke.t.sol` (9 round-trip tests).
- All value flows are plain ERC20 transferFrom/transfer — zero `.value()`
  cheatcodes, so the compound-v2 prank+value revert leak cannot recur by
  construction (prank is safe here: no value-carrying call).
- Design observations (documented, not invariant violations):
  1. v1 escrow path (`escrow_is_v2=false`) makes `redeem()` ALWAYS revert
     against a veCRV-semantics escrow — it transfers the backing to the user
     first, then asks the escrow to pull the same amount from the bond with no
     approve (`test_v1_redeem_always_reverts` pins it).
  2. `burn` pays the OWNER, not the user; a user whose escrow lock has expired
     can never `redeem` again (no re-lock path through the bond) — early/late
     exit gives the backing to the owner (UX/design fragility).
  3. `rescueHnd` after 51 weeks drains all backing (by design; not fuzzable).
- Verification: `forge test` = 12/12 pass (9 smoke + 3 invariants); invariants
  also green at runs=1000/depth=300 (300k calls per invariant).
- Analyzer untouched: pytest 21 passed, corpus 138/138 unaffected.

## Next steps (Phase 3 continued)
1. 6th protocol harness: balancer-v2 (guarded-subtraction FlashLoan path already
   PoC'd in Phase 1) or another high-value compound-family / lending protocol.
2. Optional: echidna 2.3.3 pass over the credit-guild / compound-v2 /
   hundred-bond harnesses (all pure-foundry right now).
3. If the next protocol finds nothing, widen a harness surface (multi-market
   collateral combos, interest-only rate models, reserve/claim paths) before
   moving to Phase 4.

## Key paths
- Analyzer: `/home/fatima/Downloads/static-analyzer` (venv `analyzer_env/`)
- Invariant harnesses: `invariant_projects/{basis-cash,harvest-ousd,credit-guild,compound-v2,hundred-bond}/`
- Artifacts: `opencode_artifacts/{STATUS,ROADMAP,REPORT,invariant_results,CONTINUE_HERE}.md`
- run3 findings: `opencode_artifacts/run3/` (credit-guild.json 41, compound-v2 7,
  hundred-finance.json 0)
- TVL corpus: `/home/fatima/Downloads/TVL/output_2026_08_01_22_58_07/full_code/<proto>/`
- Forge: `~/.config/.foundry/bin/forge` (1.7.1); Echidna: same dir (2.3.3)

## Historical context (Phases 1-2)
See `STATUS.md` (per-session log) and `REPORT.md` (addenda) for Phase 1
(ranking + PoC triage, null result), Phase 2 (solc coverage gap fixed -> 60
project re-run 44/60, 447 findings; all new-detector HIGHs triaged DISMISSED;
canonical artifacts = run3) and Phase 3 sessions 1-2 (basis-cash + harvest
OUSD CONFIRMED findings). Phase 3 sessions 3-4 (credit-guild), 5-6
(compound-v2) and 7-8 (hundred-bond) are summarized in the new sections above.
