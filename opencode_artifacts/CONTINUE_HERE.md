# CONTINUE HERE — session state (saved 2026-08-04 ~after Phase 2 triage)

Resume point: Phase 2 is COMPLETE. Coverage-gap fixed, 60-project re-run done
(44/60, 447 findings), new-detector HIGHs triaged (ALL DISMISSED), canonical
artifacts finalized (ranked_findings.md/.json = run3). Next phase = Phase 3
(invariant testing per protocol, per ROADMAP.md).

## Phase 2 completion summary (2026-08-04)
- Triage of all 21 new-detector HIGHs (ValueFlow 16 incl. kpk x4 + basis-cash
  x6 variants, OracleTaint 5) + 6 top pre-existing-detector HIGHs
  (morpho-blue liquidate 14, compound-v3 OracleManipulation, grace Pool,
  monolith-market reentrancy/accesscontrol, credit-guild claimGaugeRewards,
  vaultlayer) is DONE — ALL DISMISSED (standard-token atomicity,
  governance-set Chainlink feeds, permissionless-by-design entry points).
  No CONFIRMED exploit — matches Phase 1 null result.
- Verdicts recorded in `exploit_pocs/poc_verdicts.md` (Phase 2 section, 19 rows).
- Canonical artifacts FINALIZED: `ranked_findings.md/.json` now = run3
  (447 findings, HIGH 178 / MED 205 / LOW 64, 44 protocols, 0 skipped).
  `rank_findings.py` title string de-hardcoded ("Phase 1" -> generic) and
  re-run to regenerate canonical files.
- `STATUS.md`, `ROADMAP.md` (Phase 2 DONE), `REPORT.md` (Phase 2 addendum)
  all updated.
- Invariants re-verified: pytest 21 passed; corpus recall 138/138.

## Remaining (optional / Phase 3+)
- Phase 3 (invariant testing per protocol with Echidna/Foundry) — not started.
- Ranker "pure/view function" exemption (lido isValidBump class) — open idea.
- 3 remaining CEther `requireNoError` IntegerOverflow noise findings — open.
- 9 documented-unanalyzable projects remain (version-pin mixes, aave-v2,
  curve-dex Vyper, hundred-finance malformed) — expected, not regressions.

## Prior session context (see below)


## What was ACTUALLY wrong (empirical finding this session)
`solc` on PATH = dispatcher `/home/fatima/.local/bin/solc` ->
`/home/fatima/Downloads/static-analyzer/solc_versions/solc` (Python wrapper,
created last session). It remaps bare imports to in-tree source keys, picks the
installed version satisfying the most pragmas, and execs it. Coverage gap causes
were NOT pragma pins (solc 0.8.28 accepts nearly all pragmas, even exact
`0.8.15`; only rejects `^0.4.25`/`0.4.25`):
1. "Stack too deep" (large contracts) — fixed by viaIR retry.
2. Missing dependency imports (vendored libs relocated, e.g. `@openzeppelin/
   contracts/X` lives at `.../lib/openzeppelin-contracts/contracts/X`) — fixed
   by longest-suffix remapper fallback.
3. Exact-pin version mixes (reserve-protocol 0.8.19+0.8.9, envelop 0.8.21+^0.8.28,
   aave-v3 0.8.10+^0.8.20, rheo 0.8.23+0.8.26, rumpel-labs =0.8.24+tload,
   sera 0.8.24+mcopy) — genuinely uncompilable as one project; documented.
4. aave-v2 (0.6.12 inline-assembly stack-too-deep; no viaIR in 0.6.x), curve-dex
   (pure Vyper mislabeled .sol), hundred-finance (malformed) — documented.

## Changes made this session (all validated)
1. `solc_versions/` — downloaded+verified native binaries: 0.6.6, 0.8.9, 0.8.10,
   0.8.13, 0.8.15, 0.8.17, 0.8.18, 0.8.19, 0.8.20, 0.8.21, 0.8.22, 0.8.23,
   0.8.26, 0.5.7, 0.6.10 (21 total incl. existing 0.4.24, 0.5.17, 0.6.12, 0.7.6,
   0.8.24, 0.8.28). Note: `solc_versions/solc` = the dispatcher script itself.
2. `solc_versions/solc` (dispatcher) — TWO edits:
   a. `build_remappings`: added longest-suffix fallback (drop leading
      package-name components) when exact normalized-suffix match fails.
   b. `main()`: added stack-too-deep viaIR retry (chosen version >= 0.8.5),
      capturing output, injecting `viaIR:true + optimizer`, reusing the retry
      result only if stack-too-deep is gone. Also added `_has_stack_too_deep`.
3. `tools/rank_findings.py` — fixed None-entry crashes in `_collect_base_sources`
   (guard `p and`) and `_tainted_names` (guard `decl and`).

## Invariants (re-verified after changes)
- `analyzer_env/bin/python -m pytest tests/ -q` = 21 passed.
- `analyzer_env/bin/python tests/tp_corpus_report.py` = 138/138, 0 misses,
  1 unparseable (identical to before).

## Coverage numbers
- Batch whole-project compile over all 60: **51/60 OK** (was 26).
- Full CLI run (`--categories security --format json`): **44/60 projects have
  findings**, 447 total (run2 was 22/60, 121).
- run3 JSONs: `opencode_artifacts/run3/<proto>.json` (all 60; kpk re-ran
  separately after a 30-min timeout killed the batch run — 56 findings).
- 16 zero-finding projects: aave-v2, aave-v3, aladdin-dao, bumper-finance,
  cana-holdings, clever, concentrator, curve-dex, envelop, hundred-finance,
  immutablex, reserve-protocol, rheo, rumpel-labs, sera, veda (9 are the
  documented unanalyzable ones; the rest genuinely found nothing).

## run3 findings summary
- Severity: MEDIUM 303, HIGH 96, LOW 45, CRITICAL 3.
- Detectors: ZeroAddress 129, IntegerOverflow 69, Timestamp 49, Reentrancy 49,
  FrontRunning 28, StorageCollision 24, AccessControl 23, MEV 21, ValueFlow 16,
  OracleManipulation 15, OracleTaint 9, Uninitialized 9, SignatureReplay 3,
  BadRandomness 1, CrossChain 1, UncheckedCall 1.
- IntegerTruncation and CallbackReentrancy fired 0 times on TVL (only corpus TPs).

## Ranking (run3, 447 ranked, 0 skipped)
Canonical output pending. Data is SAVED at:
- `opencode_artifacts/ranked_findings.run3.md`
- `opencode_artifacts/ranked_findings.run3.json`
Buckets: HIGH 178, MEDIUM 205, LOW 64. 44 protocols ranked.
The overwrite of `opencode_artifacts/ranked_findings.md/.json` (Phase 1) was
INTERRUPTED (user aborted); do NOT clobber Phase 1 artifacts until the run3
ranking is finalized — copy `.run3.*` over canonical names when ready.

## New-detector HIGHs to triage (the priority next step)
ValueFlow (HIGH): morpho-blue supply Morpho.sol:183 + repay :283 (score 12);
vaultlayer claimDefaultedLoan NFTLendMarket.sol:527 (12); basis-cash stake
LPTokenWrapper.sol:25 + 5x distribution pools :83 (11, known classic staking-
deposit pattern — was MEDIUM from detector, ranker promoted to HIGH); kpk
requestSubscription kpkShares.sol:231 (11, x4 duplicates); monolith-market
redeem Lender.sol:346 (11) + deposit ERC4626.sol:48 (9); pumpclaw register
LastAIStanding.sol:313 (8).
OracleTaint (HIGH): sushiswap swapExactETHForTokens UniswapV2Router02.sol:647
(11); uniswap-v2 swapExactETHForTokens UniswapV2Router02.sol:476 (11); dydx-v3
getAccountValues SoloMargin.sol:1942 + OperationImpl.sol:2298 (9); treasure swap
UniswapV2Pair.sol:204 (8, AMM self-math — likely FP); treasure mint/burn (6);
compound-v3 absorbInternal CometWithExtendedAssetList.sol:1065/1076 (5).
Likely FP classes to verify: AMM routers/pairs using their own getReserves
(sushiswap/uniswap-v2/treasure) = by-design; compound-v3 getPrice has a
staleness check the detector may have missed. morpho-blue/basis-cash ValueFlow
need PoC-level review (fee-on-transfer conditional). dydx-v3 relies on external
oracle with TWAP-like guards — check `_getPrice`/staleness.

## Next steps (in order)
1. Triage the ~25 new-detector HIGHs above (read source, classify TP/FP/needs-
   PoC), mirroring Phase 1's `poc_verdicts.md` process.
2. When satisfied: copy `ranked_findings.run3.md/.json` over the canonical
   `ranked_findings.md/.json` (Phase 1 had HIGH 36/MED 62/LOW 23 = 121; run3 is
   HIGH 178/MED 205/LOW 64 = 447).
3. Update `opencode_artifacts/STATUS.md` and `ROADMAP.md` with coverage numbers
   (44/60, 447 findings) + verdict summary.
4. Update `opencode_artifacts/poc_verdicts.md` with new triage verdicts.

## Key paths
- Analyzer: `/home/fatima/Downloads/static-analyzer` (venv `analyzer_env/`)
- Dispatcher: `/home/fatima/Downloads/static-analyzer/solc_versions/solc`
- TVL corpus: `/home/fatima/Downloads/TVL/output_2026_08_01_22_58_07/full_code/<proto>/`
- CLI: `analyzer_env/bin/python main.py analyze "<proto_dir>" --categories
  security --format json --output out.json`
- Ranker: `analyzer_env/bin/python tools/rank_findings.py --findings-dir
  opencode_artifacts/run3 --out ... --out-json ...`
- Logs: `/tmp/opencode/run3.log`, `/tmp/opencode/kpk_run.log` (both in /tmp —
  wiped on reboot, but not needed anymore).
