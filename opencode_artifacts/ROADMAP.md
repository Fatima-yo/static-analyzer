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

1. Install Echidna (and confirm Foundry from Phase 1). — DONE: Echidna 2.3.3 at
   `~/.config/.foundry/bin/echidna`; Foundry 1.7.1.
2. Pick protocols: basis-cash (known findings/shape) + one more to be chosen
   (candidates: harvest-finance OUSD, balancer-v2, compound-v2).
3. Scaffold Foundry project per protocol; vendor contracts + deps; make compile.
   — DONE for basis-cash (`invariant_projects/basis-cash/`).
4. Invariant suites (foundry fuzz + echidna):
   - Accounting conserves: sum(balances) == totalSupply / rebasing credits math
   - CEI: no fund drain via reentrant callback
   - Reward-rate consistency: rate == totalRewards / duration; no early-exit abuse
   - Single-sided redemption / migration can't profit at protocol expense
   - Protocol can't lose value to msg.sender
   — IN PROGRESS. basis-cash: 3 invariants fuzzed (foundry). One VIOLATED:
     Boardroom phantom/retroactive reward inflation (see
     `opencode_artifacts/invariant_results.md`). Echidna pass pending.
5. Triage failures into real bugs; cross-reference analyzer findings.
   — basis-cash finding triaged as CONFIRMED (MEDIUM, fund-lock DoS); not
     visible to the static analyzer (no Boardroom findings in run3).
NEXT: second protocol harness (harvest-finance OUSD or compound-v2),
Echidna pass over the basis-cash harness.

Phase 3 session 2 (2026-08-04) — both remaining steps DONE:
- Echidna 2.3.3 pass over basis-cash: `test/EchidnaBasisCash.sol` +
  `echidna.yaml` (property mode, 50k tests). Independently reproduces the same
  Boardroom finding (identical shrunk 4-call shape); other 2 invariants pass.
  Two independent fuzzers agree.
- Second protocol DONE: harvest OUSD (`invariant_projects/harvest-ousd/`,
  solc 0.8.28). 4 invariants fuzzed (foundry): 3 HOLD at 1000 runs; 1 fails.
- **CONFIRMED finding #2 (MEDIUM, fund-lock DoS)**: OUSD yield delegation +
  negative rebase underflows `balanceOf(target)` (panic 0x11) — source credits
  are frozen and folded into the target; a supply shrink raises cpt until the
  subtraction underflows, locking the delegated account. 2 deterministic repros
  in `test/Findings.t.sol`. Static-invisible (run3 harvest findings are a
  different class: SWC-114 approve + reentrancy borderline-FP).
- Third protocol harness (balancer-v2 / compound-v2 / credit-guild) remains
  the next slot; also optional echidna pass over harvest-ousd.

Phase 3 sessions 3-4 (2026-08-04) — third protocol DONE (credit-guild):
- Harness `invariant_projects/credit-guild/`: full ECG wiring, two EIP-1167
  LendingTerm clones, 8 actors, all lending-loop actions fuzzable.
- 7 invariants ALL HOLD (runs=200/120, 1000 fuzz-runs, stressed 1500/200);
  9/9 smoke tests pass. No new finding — the first clean high-value harness.
- All 41 run3 credit-guild findings cross-checked and DISMISSED (10 HIGH
  reentrancy = internal pure accounting; 2 HIGH Timestamp + BadRandomness
  loanId = design intent; AccessControl distribute = permissionless-by-design;
  rest standard FPs). The green invariant suite corroborates those dismissals.
- Next slots: 4th protocol harness (balancer-v2 / compound-v2) and/or an
  echidna pass over harvest-ousd / credit-guild.

Phase 3 sessions 5-6 (2026-08-04) — fourth protocol DONE (compound-v2):
- Harness `invariant_projects/compound-v2/`: flattened 0.4.x CEther.sol against
  a permissive SimpleComptroller + White-Paper rate model, fuzzed through 8
  **real Actor contracts** (each owns its ETH, calls markets with itself as
  msg.sender — no value cheatcodes).
- 3 invariants ALL HOLD (ctoken supply exact, ETH conservation exact, borrow
  ledger within 1e9) at runs=200 and 1000, plus --fuzz-runs 5000; 9/9 smoke
  tests pass. No new finding; the 7 run3 compound-v2 findings (SWC-114 approve
  pattern-TP, 3x ZeroAddress, 3x error-formatting IntegerOverflow) dismissed.
- Root-caused a **foundry prank+value revert leak** (fuzz-only 1e24 loss that
  every hand-replay passes); the Actor-contract redesign eliminated the whole
  cheatcode-value class of bugs from the harness.
- Next slots: 5th protocol harness (balancer-v2) and/or an echidna pass over
  credit-guild / compound-v2.

Phase 3 sessions 7-8 (2026-08-04) — fifth protocol DONE (hundred-finance):
- Harness `invariant_projects/hundred-bond/`: vendored Polygon HundredBond
  (solc 0.8.0, OZ 4.4.1), mock HND + veCRV-semantics MockEscrow, owner-routed
  handler with 8 actors (no value cheatcodes — the compound-v2 prank+value
  lesson applied by construction).
- 3 invariants ALL HOLD (HNDb backing exact, HNDb supply exact, HND conserved
  == 1M ether) at runs=200 and 1000/depth=300; 9/9 smoke tests pass. No
  protocol flaw in the v2 path.
- Design observations (not losses): the v1 escrow path makes `redeem()`
  always revert against a veCRV-semantics escrow (transfers backing to the
  user before the escrow pull, no approve — see
  `test_v1_redeem_always_reverts`); `burn` pays the owner, not the user; a
  user's expired escrow lock can never be redeemed again through the bond.
- run3 `hundred-finance.json` = 0 findings (nothing to cross-check).
- Next slots: 6th protocol harness (balancer-v2) and/or an echidna pass over
  the newer harnesses.

Phase 3 sessions 9-10 (2026-08-04) — sixth protocol DONE (balancer-v2):
- Harness `invariant_projects/balancer-v2/`: vendored the full Vault corpus
  (solc 0.7.6, pure ERC20) with 2 constant-product MINIMAL_SWAP_INFO mock
  pools, a permissive authorizer, 3 flash-loan recipients (repay / no-repay /
  under-repay) and 8 pranked actors; all swap/join/exit/flash-loan/
  internal-balance actions fuzzable.
- 8 invariants (token conservation exact, vault-ledger exact — physical
  vault balance == pool virtual cash + internal balances — and pool-share
  conservation) ALL HOLD at 200 and 1000 runs (300k calls/invariant); 8/8
  smoke tests pass. Teeth-check: removing the internal-balance credit in
  `UserBalance._depositToInternalBalance` makes all 3 ledger invariants FAIL,
  so they demonstrably catch internal-accounting bugs.
- All 19 run3 balancer-v2 findings DISMISSED — the guarded-subtraction
  flashLoan/pool-balance/asset-transfer/swap-index paths were exercised green
  (flashLoan under-repay/no-repay reverts hit `BAL#515` atomically); the 2
  ZeroAddress are authenticate-gated governance + a constructor-only param.
- Next slots: 7th protocol harness (lido / ionic-protocol / rocket-pool) and/or
  an echidna pass over the newer harnesses.

## Phase 5 — Slither corpus sweep of the 1,574-protocol TVL corpus (2026-08-14)
Status: coverage COMPLETE (~99%, `slither_2026_08_14_final`); **triage of
High-impact findings is the next step** (per user: "clean up to push coverage,
then we go for the high-impact").

1. Done — tooling + run: `tools/slither_worker.py` + `run_slither_corpus.sh`.
   Final run: 1,584 OK / 11 VYPER / 16 FAIL (13 unique real FAILs, mostly
   unfixable). 47k+ findings in `top_findings.tsv`.
2. NEXT — aggregate High-impact findings (incorrect-return, reentrancy-*,
   unchecked-transfer, arbitrary-send-erc20, controlled-delegatecall, ...) from
   `slither_2026_08_14_final/top_findings.tsv` + `results/*.json` by detector
   and protocol; produce a protocol-level triage report.
3. Optional cleanup: remove leftover `*.sanitized` / `.extracted` dirs from
   `output/full_code/` (3 stale `.sanitized` FAIL rows).

---

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
