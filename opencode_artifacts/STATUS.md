# Analyzer precision work — session status

Date: 2026-08-04 (Phase 2 session log appended; Phase 1 log below unchanged)

## Objective
Reduce analyzer false-positive rate on the 22-protocol real-world corpus while
keeping 100% TP recall on the SmartBugs true-positive corpus.

## Current verified state
- Corpus recall: 138/138 = 100.0% (base22.json), 0 misses, 1 unparseable
  (parity_wallet_bug_1), 4 excluded. `denial_of_service` fires on 4/6 corpus
  expectations.
- pytest: 21 passed.
- Protocol aggregate: old triaged baseline (run2) = 113 -> newruns10 = 121.
- Timestamp severity scheme: randomness=HIGH, equality=MEDIUM, gating=LOW
  (added 2026-08-03; corpus recall unaffected). The 9 accepted SWC-116 gating
  findings are now LOW.

## Per-detector delta (run2 triaged -> newruns10)
| Detector        | old | new | delta |
|-----------------|-----|-----|-------|
| AccessControl   | 6   | 6   | 0     |
| CrossChain      | 1   | 1   | 0     |
| FrontRunning    | 7   | 8   | +1    |
| IntegerOverflow | 38  | 35  | -3    |
| MEV             | 7   | 6   | -1    |
| OracleManipulation| 2  | 2   | 0     |
| Reentrancy      | 0   | 2   | +2    |
| SignatureReplay | 1   | 1   | 0     |
| StorageCollision| 6   | 6   | 0     |
| Timestamp       | 0   | 9   | +9    |
| ZeroAddress     | 45  | 45  | 0     |
| TOTAL           | 113 | 121 | +8    |

## Changes made this session (all verified 138/138 after each)
1. context.py QUERY_MEMBER_RE: rewritten with scoped `(?i:...)` flags +
   `(?=[A-Z0-9_])` lookahead. Root cause: previous `(?![a-z])` under
   re.IGNORECASE case-folded the lookahead so camelCase members (`canCall`,
   `isRegistered`) were never treated as queries -> veda Auth.sol:41 and
   forta RewardsDistributor.sol:153 reentrancy FPs eliminated. (Reentrancy 10->4.)
2. context.py function_has_mev_protection: dropped the over-broad `"amount"`
   body-check substring (any `amount > 0` counted as slippage protection,
   wrongly suppressing rocket-pool RETH burn); added `==` + price/target/
   expected/exact pinning detection (basis-cash Treasury buyBonds exact-price
   pin is genuine protection). RETH burn MEV restored; Treasury FP stays gone.
3. other.py _guard_checked_keys: only relational operators (`<`,`<=`,`>`,`>=`)
   now count as overflow guards. An equality early-exit like
   `if (amount == 0) return;` does not bound a later `amount - x`, so
   balancer-v2 AssetTransfersHandler.sol:72 (`amount -= deductedBalance`)
   overflow finding was restored.
4. context.py timestamp precision (Stage 1): timestamp_uses now returns
   (node, kind, ancestor_chain); new `_ts_use_benign()` suppresses gating uses
   where the comparison's other side references deadline/expiry-named
   parameters, locals, or struct members, or calls pause/buffer/window/timer
   helpers. Keeps: randomness; constant comparisons (timed_crowdsale);
   epoch/cadence gating vs state arithmetic (governmental_survey, lottopollo).
   Timestamp 17 -> 9. NOTE: view/pure exclusion was rejected because the
   corpus TP timed_crowdsale is itself a view function.

5. security.py detect_timestamp severity scheme (2026-08-03):
   randomness=HIGH, equality=MEDIUM, relational gating=LOW; picks the
   max-severity non-benign use per function. Presentation-only; corpus recall
   unaffected. The 9 accepted SWC-116 gating findings are now LOW.
6. context.py _is_math_member_call (2026-08-03): recognizes OpenZeppelin
   SafeCast casts (`toInt256()`, `toUint128()`, ... via _SAFE_CAST_RE) as pure
   library conversions, NOT external high-level calls. Root cause of the 2
   harvest OUSD Reentrancy FPs: `creditBalances[_account].toInt256()` was
   treated as an external call on a state-stored contract, producing a
   CEI-violation FP. Reentrancy 4 -> 2.
7. other.py _find_overflow_ops (2026-08-03): skips arithmetic used purely as an
   array index (`fullMessage[i+2]`) — bounded by collection length, not a
   reportable overflow. Removed the 5 CEther `requireNoError` index-arithmetic
   findings (2532/2533/2536 plus the index part of 2534/2535); 3 single
   findings remain in that pure helper (2525 `length+5`, 2534 `48+errCode/10`,
   2535 `48+errCode%10`). IntegerOverflow 40 -> 35.

## New-finding classification (vs run2 baseline, newfindings_s1.txt)
Real / pattern-TP (low exploitability):
- basis-cash Reentrancy InitialCashDistributor.sol:42 + InitialShareDistributor.sol:42
  (genuine CEI violation: `once=false` written after the transfer loop; a
  reentrant `distribute()` passes `require(once)`; low severity, trusted targets)
- compound-v2 FrontRunning CEther.sol:1131 + harvest OUSD.sol:404 (SWC-114 approve)
Accepted SWC-116 gating (benign in practice):
- basis-cash Timestamp x9: BAC*Pool:208 x5, DAIBACLPTokenSharePool:189,
  DAIBASLPTokenSharePool:178, Treasury.sol:108 (migrate startTime),
  Treasury.sol:139 (_allocateSeigniorage cadence)
Resolved since newruns8 triage:
- harvest OUSD Reentrancy :362/:373 borderline FP: root cause was the
  SafeCast `toInt256()` call misidentified as an external call; now suppressed.
- compound-v2 IntegerOverflow CEther index-arithmetic noise (i+0..i+4 in the
  pure `requireNoError` helper): index arithmetic no longer reported; 3 single
  findings remain in that helper (see change 7).

## Artifacts (persistent; /tmp is wiped on reboot)
- run2/           old analyzer output (113 triaged baseline)
- newruns7/       previous state (136)
- newruns9/       intermediate (128, after severity change)
- newruns10/      current (121)  <-- final
- base19.json     corpus before timestamp discriminator
- base20.json     corpus after timestamp discriminator (138/138)
- base21.json     corpus after severity change (138/138)
- base22.json     corpus after SafeCast + index-arith fixes (138/138)  <-- final
- newfindings_final2.txt, newfindings_s1.txt

## Phase 1 (in progress)
- Foundry 1.7.1 installed (forge/cast/anvil/chisel) at `~/.config/.foundry/bin`
  (added to ~/.bashrc; XDG_CONFIG_HOME redirects from the default ~/.foundry).
- `tools/rank_findings.py` built and run: recompiles each protocol once with
  solc 0.8.24 (venv wrapper), resolves each finding to its enclosing function,
  scores exploitability (exposure, def-use taint, user-controlled call target,
  value-to-user, access control, reentrancy guard, callback-capable receiver).
- `ranked_findings.md` + `ranked_findings.json`: 121/121 ranked, 0 skipped.
  Buckets: HIGH 50, MEDIUM 53, LOW 18. All StorageCollision score 1 (LOW).
- Top finds: rocket-pool RocketTokenRETH `burn` (oracle-priced redeem,
  FrontRunning/MEV, score 12); balancer-v2 FlashLoans `flashLoan` (11);
  hegic `bridgeInit` CrossChain (10); peer `removeMembers` AccessControl (10);
  basis-cash reentrancy pair score 8; compound CEther `approve` (9).
- Foundry PoC harness `opencode_artifacts/exploit_pocs/` (forge 1.7.1,
  solc 0.8.35): 5 exploit-attempt tests, all PASS (2000 fuzz runs on the
  flash-loan guarded-subtraction). `poc_verdicts.md` documents verdicts.
- PoC triage verdict: top 15 candidates + ZeroAddress/StorageCollision classes
  ALL DISMISSED (guards present, guarded arithmetic, bounded TWAP, oracle/
  trusted-operator design). No CONFIRMED exploit. Root cause of FPs: ranker's
  access-control guard detection misses internal-helper guards
  (`_requireGroupCurator`) and the OZ `initializer` modifier; constructors
  inflated by meaningless no-guard signals.
- Ranker refinements DONE (v2, 2026-08-03): (1) internal guard-helper
  recognition (`_calls_guarded_helper` — catches `_requireGroupCurator` and
  qualified guarded-initializer calls like `L2GatewayToken._initialize` with
  the OZ `initializer` modifier); (2) constructors treated as guarded (args not
  attacker-callable); (3) `.transfer`/`.send` excluded from callback_capable
  (2300-gas stipend cannot re-enter). Result: HIGH 50->36, MEDIUM 53->62,
  LOW 18->23; peer `removeMembers` 10->8 (guard now seen), rETH `burn`
  12->11 and balancer `flashLoan` 11->10 (callback over-approx dropped),
  ZeroAddress constructor class de-skewed to MEDIUM/LOW. Canonical
  ranked_findings.md/.json are now v2. pytest still 21 passed (analyzer core
  untouched).
- 15 protocol JSONs carry the 121 findings; the other 7 (aladdin-dao, bumper,
  cana-holdings, clever, concentrator, immutablex, veda) are empty leftovers.
- Phase 0 (SQLite pipeline migration) done in /home/fatima/Downloads/TVL:
  src/db.py, src/migrate_to_sqlite.py, scripts 01-05 + run.sh on OUTPUT_DB /
  DISCOVERY_CACHE_DB; output/pipeline.db (7,220 rows) + discovery_cache.db.

## Re-run commands
Protocols:
  analyzer_env/bin/python main.py analyze \
    "/home/fatima/Downloads/TVL/output_2026_08_01_22_58_07/full_code/<proto>" \
    --categories security --format json -o /tmp/opencode/newrunsX/<proto>.json
Tests:
  analyzer_env/bin/python -m pytest tests/ -q
Corpus:
  analyzer_env/bin/python tests/tp_corpus_report.py --json /tmp/opencode/baseN.json
Diff (old vs new): inline python keyed by (detector, basename, line_number).

## Phase 2 (2026-08-04) — solc coverage gap + 60-project re-run + triage
- Coverage-gap root cause fixed (NOT pragma pins): solc-on-PATH is a version
  dispatcher (`solc_versions/solc`); real causes were (1) "Stack too deep" on
  large contracts -> viaIR retry, (2) missing vendored-dep imports ->
  longest-suffix remapper fallback. 15 native binaries added (0.5.7..0.8.28).
- Whole-project compile batch: 51/60 OK (was 26). Full CLI re-run: **44/60
  projects with findings, 447 total** (run2 was 22/60, 121).
- 9 projects documented unanalyzable (version-pin mixes: reserve-protocol,
  envelop, aave-v3, rheo, rumpel-labs, sera; aave-v2 stack-too-deep pre-viaIR;
  curve-dex = Vyper mislabeled .sol; hundred-finance malformed). 7 more
  genuinely zero-finding (aladdin-dao, bumper-finance, cana-holdings, clever,
  concentrator, immutablex, veda).
- Invariants intact after all changes: pytest 21 passed, corpus 138/138.
- New detectors (semantic.py): value_flow, callback_reentrancy,
  integer_truncation, oracle_taint. On TVL: ValueFlow 16 / OracleTaint 9 /
  CallbackReentrancy 0 / IntegerTruncation 0.
- run3 severity: MEDIUM 303, HIGH 96, LOW 45, CRITICAL 3 (447 total).
- Ranker robustness: fixed two None-entry crashes (_collect_base_sources,
  _tainted_names); 447/447 ranked, 0 skipped.
- **Triage (2026-08-04)**: all 21 new-detector HIGHs (ValueFlow 16 incl. kpk x4
  + basis-cash x6 variants, OracleTaint 5) + top 6 pre-existing-detector HIGHs
  spot-checked (morpho liquidate 14, compound-v3 OracleManipulation, grace
  Pool, monolith reentrancy, credit-guild claimGaugeRewards, vaultlayer) are
  **DISMISSED** — standard-token atomicity, governance-set Chainlink feeds,
  permissionless-by-design entry points. No CONFIRMED exploit (matches Phase 1
  null result). Verdicts in `exploit_pocs/poc_verdicts.md` (Phase 2 section).
- **Canonical artifacts now final**: `ranked_findings.md/.json` = run3
  (447 findings, HIGH 178 / MEDIUM 205 / LOW 64, 44 protocols). The Phase 1
  v2 artifacts (HIGH 36/MED 62/LOW 23, 121) are superseded.

## Phase 3 (2026-08-04) — invariant testing (first protocol: basis-cash)
- Harness `invariant_projects/basis-cash/` (foundry 1.7.1, solc 0.6.12,
  standalone handler, no forge-std): `test/BasisCashHandler.sol`,
  `test/Invariants.t.sol`, `test/Findings.t.sol`; vendored basis-cash + OZ at
  `src/`. Fuzz actions roll block + warp +12s per action (constant timestamps
  are a harness artifact that over-credits all stakers retroactively).
- Invariants: (1) earnings(claimed+pending) <= allocated — **VIOLATED**;
  (2) no reward without stake — holds; (3) share books balance — holds.
- **CONFIRMED finding (MEDIUM, fund-lock DoS)**: Boardroom `withdraw`/`stake`
  rewrite the last snapshot's `totalShares` retroactively; remaining directors'
  per-snapshot claims inflate past the cash the boardroom holds -> late
  claimers' `claimDividends`/`withdraw` revert (stuck funds). Reproduced by
  fuzzer (4-call counterexample, multiple seeds/runs) and deterministic
  scenario. Details + cross-ref in `opencode_artifacts/invariant_results.md`.
- Tooling learnings: solc 0.6.x `assert(false)` == INVALID opcode == Foundry
  "InvalidFEOpcode" (use `require`+message); public fuzzable setup helpers must
  be internal; `allocateSeigniorage` pulls via transferFrom (approve first).
- Analyzer untouched; pytest/corpus unaffected (docs only this session).

## Phase 3 session 2 (2026-08-04) — Echidna cross-check + second protocol
- **Echidna 2.3.3 pass over the basis-cash harness**: crytic-compile 0.4.2
  installed in a dedicated venv; solc 0.6.12 wired into solc-select (crytic
  prefers solc-select global over PATH). Verified echidna honors Foundry
  `prank`/`startPrank`/`stopPrank`/`warp`/`roll`. `test/EchidnaBasisCash.sol` +
  `echidna.yaml` (property mode, 50k tests, whitelisted action fns). Result:
  `echidna_earnings_never_exceed_allocated` FAILED with the same 4-call shape
  (`stake->stake->allocate->withdraw`); the other two pass. **Two independent
  fuzzers agree** on the Boardroom phantom-reward finding.
- **Second protocol: harvest OUSD** (`invariant_projects/harvest-ousd/`, solc
  0.8.28): vendored OUSD + VaultStorage/Governable/OZ deps; `HarvestHandler.sol`
  (handler is governor + vault; 8 actors; transfer/transferFrom/mint/burn/
  changeSupply/rebaseOptIn/Out/governanceRebaseOptIn/delegateYield/
  undelegateYield/warpDays); `OUSDHarness` exposes internal credit maps.
- Invariants (4): sum(balances)<=supply; creditsConservation; nonRebasing-
  Conservation; nonRebasing<=supply. At 200 AND 1000 runs: 3 HOLD, 1 fails.
- **CONFIRMED finding #2 (MEDIUM, fund-lock DoS)**: OUSD yield delegation +
  negative rebase. `delegateYield` freezes the source's credits and folds them
  into the target; `balanceOf(target)` = rebased-combined - frozen-source-
  credits (OUSD.sol:191-194). A `changeSupply` shrink raises cpt; once the
  rebased combined value < frozen source credits, the subtraction underflows
  (panic 0x11) and the target's account reverts on every read/transfer
  (locked). Source is fully insulated; target absorbs the whole loss. Repro'd
  deterministically (`test/Findings.t.sol`, 2 scenarios incl. double-halve with
  no opt-out). Static-invisible (run3 harvest findings were SWC-114 approve +
  a reentrancy borderline-FP — a different issue class entirely).
- Total: 2 CONFIRMED static-invisible findings so far (basis-cash Boardroom,
  harvest OUSD). Analyzer untouched; pytest/corpus unaffected.

## Open items (optional)
- Consider a run-once/flag guard (`require(once)` + write-after-call) nuance for
  the basis-cash distributors, or accept as low-severity findings.
- Decide whether the 3 remaining CEther `requireNoError` IntegerOverflow
  findings (pure error helper: `length+5`, `48+errCode/10`, `48+errCode%10`)
  should be suppressed too. NOTE: any pure-function suppression must be
  re-verified against the corpus before shipping (recall risk).
- Optional future: a "pure/view function" exemption in the ranker to de-skew
  no-guard signals on non-attackable reads (lido isValidBump class).
