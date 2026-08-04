# ROADMAP — from pattern findings to real vulnerabilities

Status: 2026-08-03. Phase 0 (SQLite migration of the TVL pipeline data layer)
is DONE: `src/db.py` + `src/migrate_to_sqlite.py`, seeded
`output/pipeline.db` (7,220 rows, parity ok) and `output/discovery_cache.db`
(10,060 keys); scripts 01-05 + run.sh switched to `OUTPUT_DB` /
`DISCOVERY_CACHE_DB`. All four phases below are queued in order. Cross-cutting
rule after every code change: `pytest tests/` green (21) + corpus recall
138/138 (base22.json) + protocol re-run, then persist under
`opencode_artifacts/`.

Current base state: run2 triaged baseline = 113; newruns10 = 121 findings, all
pattern-level. Tooling: Foundry 1.7.1 installed (Phase 1 PoC harness lives in
opencode_artifacts/exploit_pocs/); Echidna NOT installed yet (Phase 3).

---

## Phase 1 — Exploitability ranking + Foundry validation
Goal: convert pattern findings into confirmed or dismissed real bugs.

1. Install Foundry (foundryup). Add it to PATH persistently.
   DONE 2026-08-03: forge 1.7.1 at ~/.config/.foundry/bin (PATH in ~/.bashrc).
2. Build an exploitability ranker — new standalone tool, non-invasive:
   `tools/rank_findings.py` reading `newruns10/*.json` + source + AST.
   DONE 2026-08-03: 121/121 ranked -> ranked_findings.md/.json (HIGH 50,
   MEDIUM 53, LOW 18). Signals: exposure, def-use taint to the flagged node,
   user-controlled call target, value-to-user, no guard, no reentrancy guard,
   callback-capable receiver; score = severity + weighted signals.
3. Produce `opencode_artifacts/ranked_findings.md`: full ranking + top-N list.
   DONE (same run as #2).
4. For the top candidates (start: basis-cash InitialCash/InitialShareDistributor
   reentrancy pair; compound CEther approve; basis-cash Treasury migrate):
   - Minimal Foundry PoC project per finding (vendor contract + deps)
   - Write exploit test (unit + fuzz); attempt the actual drain
   - Record outcome per finding: CONFIRMED / DISMISSED / NEEDS-DEP
   - Deliverable: `opencode_artifacts/exploit_pocs/` + outcomes table in report.
   DONE 2026-08-03: harness + 5 exploit-attempt tests PASS (fuzz 2000);
   `poc_verdicts.md` — top-15 candidates + ZeroAddress/StorageCollision classes
   all DISMISSED; no confirmed exploits. Detector FPs root-caused (guard-helper
   detection, constructor skew, transfer-callback over-approx).

Exit criteria: every HIGH-ranked finding has a verdict; report updated with
"confirmed vulnerabilities" section.
DONE 2026-08-03 (v2 ranking, 36 HIGH): all 36 HIGH findings have verdicts in
`poc_verdicts.md` — every one DISMISSED by PoC and/or code inspection; the
"confirmed vulnerabilities" section is intentionally empty (honest result).
Phase 1 complete.

## Phase 2 — Semantic detectors
Goal: catch bug classes the pattern detectors cannot see. One detector at a time;
each must keep corpus 138/138 + pytest green + survive protocol re-run + triage.

Status: DONE 2026-08-04.

1. Value-flow / balance-delta detector: track ETH + ERC20 balance changes around
   external calls; flag where a malicious counterparty can redirect funds.
   DONE — `value_flow` (MEDIUM default, HIGH only for attacker-controlled
   share/supply crediting); 16 findings on TVL (morpho-blue supply/repay,
   vaultlayer, basis-cash staking, kpk subscription, monolith redeem/deposit,
   pumpclaw). All triaged DISMISSED (standard-token atomicity).
2. ERC777/ERC721 callback reentrancy detector (DAO-hack class): external calls to
   token-receiver-hook contracts without a guard. Watch corpus reentrancy TPs
   that use `.transfer` (callbacks there are limited to 2300 gas — do not regress).
   DONE — `callback_reentrancy`; 0 TVL findings (corpus TPs only) — by design.
3. Integer truncation / rounding-down detector: `(x/y)*y != x` value-loss patterns
   in mint/burn/reward/credit accounting.
   DONE — `integer_truncation`; 0 TVL findings (corpus TPs only).
4. Oracle-taint detector: price/oracle-derived values reaching sensitive ops
   (transfers, mint amounts, balances) across contracts.
   DONE — `oracle_taint` (Chainlink HIGH / AMM spot MEDIUM, requires no
   staleness check); 9 findings on TVL (sushiswap/uniswap-v2 routers, dydx-v3
   getAccountValues, treasure pair, compound-v3 absorb). All triaged DISMISSED
   (governance-set Chainlink feeds / AMM self-math by design).

Coverage-gap fix (part of Phase 2): solc dispatcher `solc_versions/solc`
gained a viaIR retry for "Stack too deep" + longest-suffix remapper fallback
for vendored imports; 15 native solc binaries added (0.5.7..0.8.28).
Whole-project compile 51/60 OK (was 26); full run 44/60 protocols with
findings, 447 total (was 22/60, 121). Canonical ranking updated:
`ranked_findings.md/.json` = run3 (447, HIGH 178 / MED 205 / LOW 64).

Deliverable per detector: implemented + verified + triaged, findings folded into
`REPORT.md`, artifacts persisted.
DONE — detector verdicts in `exploit_pocs/poc_verdicts.md` (Phase 2 section);
all new-detector HIGHs DISMISSED; no confirmed exploits (consistent with
Phase 1 null result).

## Phase 3 — Invariant testing per protocol
Goal: let a fuzzer find real bugs in real protocols.

1. Install Echidna (and confirm Foundry from Phase 1).
2. Pick protocols: basis-cash (known findings/shape) + one more to be chosen
   (candidates: harvest-finance OUSD, balancer-v2, compound-v2).
3. Scaffold Foundry project per protocol; vendor contracts + deps; make compile.
4. Invariant suites (foundry fuzz + echidna):
   - Accounting conserves: sum(balances) == totalSupply / rebasing credits math
   - CEI: no fund drain via reentrant callback
   - Reward-rate consistency: rate == totalRewards / duration; no early-exit abuse
   - Single-sided redemption / migration can't profit at protocol expense
   - Protocol can't lose value to msg.sender
5. Triage failures into real bugs; cross-reference analyzer findings.

## Phase 4 — Exploit-archetype library
Goal: encode what we learned from real exploits so it is reusable.

1. Curate ~40-60 archetypes from Rekt leaderboard + public audit reports
   (e.g. oracle price skew, rounding skim, missing min-receive, reward-claim
   after exit, fee-on-transfer misaccounting, single-sided pool drain, ...).
2. Encode each as a semantic check (AST pattern + value-flow), reusable modules.
3. Run the library over the 22 protocols; triage; fold the strongest checks into
   the detector set; keep corpus green throughout.

---

## Artifact conventions
- All outputs in `opencode_artifacts/` (survives reboot; /tmp does not).
- Protocol JSON runs: `<phase>-tagged` dirs (newruns10 currently final).
- Corpus jsons: baseN.json; bump on each analyzer change.
- Verification commands: pytest, tp_corpus_report.py, protocol xargs re-run.
