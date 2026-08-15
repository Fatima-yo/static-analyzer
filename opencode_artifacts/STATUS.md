# Analyzer precision work — session status

Date: 2026-08-05 (Phase 3 session log appended; Phase 1/2 logs below unchanged)

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
    "/home/fatima/Downloads/TVL/output/corpus_2026_08_01/full_code/<proto>" \
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

## Phase 3 sessions 3-4 (2026-08-04) — third protocol: credit-guild
- Harness `invariant_projects/credit-guild/` (solc 0.8.13, evm london):
  full Ethereum Credit Guild wiring — Core roles, CreditToken/GuildToken,
  ProfitManager, RateLimitedMinter, AuctionHouse, two EIP-1167 LendingTerm
  clones. Handler is core admin; terms/minter hold their protocol roles.
  `test/CreditGuildHandler.sol`, `test/Invariants.t.sol`, `test/Smoke.t.sol`.
- 7 invariants (credit/guild/collateral/gauge-weight/votes conservation +
  issuance consistency + issuance-within-caps): **ALL HOLD** at runs=200/120,
  `--fuzz-runs 1000`, and a stressed 1500/200 run. Fuzzer reaches every action
  (~1300 actions/run, fail_on_revert=false).
- 9 deterministic smoke tests all pass after triage (see invariant_results.md
  for the wiring/semantics fixes: LendingTerm can't deploy directly -> verified
  EIP-1167 bytes.concat clone; maxGauges=0 default blocks incrementGauge ->
  setMaxGauges(10); ProfitManager needs CREDIT_MINTER/BURNER for the PnL loss
  burn path; call() sets callTime not closeTime; partialRepay needs remaining >
  minBorrow(100e18); forgive needs fully-elapsed auction; warpDays caps at 30d;
  surplus buffer is a loss-absorber, not donor-reclaimable; gaugeWeightTolerance
  raised to 2e18 so balanced gauges don't dead-cap 2nd borrows).
- **run3 cross-check: all 41 credit-guild findings DISMISSED.** The 10 HIGH
  reentrancy (ERC20Gauges/ERC20MultiVotes) are internal pure accounting (no
  external calls); the 2 HIGH Timestamp + BadRandomness (loanId = keccak of
  timestamp, an identifier) are design-intent; AccessControl `distribute` is
  permissionless-by-design; StorageCollision/IntegerOverflow/ZeroAddress/
  Uninitialized/FrontRunning/MEV are standard FPs. The green invariant suite is
  independent corroboration for the reentrancy/timestamp dismissals.
- Total: 2 CONFIRMED static-invisible findings (basis-cash, harvest OUSD);
  credit-guild is the first clean high-value harness. Analyzer untouched;
  pytest 21 passed / corpus 138/138 unaffected.

## Phase 3 sessions 5-6 (2026-08-04) — fourth protocol: compound-v2
- Harness `invariant_projects/compound-v2/` (solc 0.5.8, evm istanbul):
  flattened 0.4.x `CEther.sol` + `src/SimpleComptroller.sol` (permissive policy
  hooks, 1e18 prices, 1.08e18 liquidation incentive, faithful
  liquidateCalculateSeizeTokens) + `src/SimpleInterestRateModel.sol`
  (White-Paper, under the borrow-rate cap). Two CEther markets (exchange rate
  0.02e18), 8 **real Actor contracts** owning 1M ETH each that call the markets
  with themselves as `msg.sender` (`test/Actor.sol`), handler routes
  mint/redeem/borrow/repay/repayBehalf/liquidate/transfer/transferFrom/warpBlocks.
- 3 invariants (ctokenConservation exact, ethConservation exact == 8e24,
  borrowLedger within 1e9): **ALL HOLD** at runs=200/depth=120, invariant
  runs=1000, and `--fuzz-runs 5000`; 9/9 smoke tests pass.
- **Foundry prank+value revert leak (root-caused this session):** the first
  handler used `vm.startPrank(actor)` + high-level `c.mint.value(x)()`. Under
  the invariant fuzz runner a reverting value call lost exactly one full actor
  balance (1e24): conservation broke to 7e24 with the handler's own post-action
  check never firing (the revert unwound the whole handler call before _tick),
  and every hand-replay of the shrunken counterexample (direct / outer-prank /
  low-level-swallowed-reverts) PASSED — the loss is fuzz-context-only. A
  low-level `.call.value()`-from-a-0-balance-handler variant instead silently
  did nothing (caught by a temporary activity invariant). Fix: real Actor
  contracts doing ordinary atomic EVM transfers — no value cheatcodes at all.
  After the redesign: conservation green, activity verified, instrumentation
  stripped.
- **run3 cross-check: all 7 compound-v2 findings DISMISSED.** SWC-114 `approve`
  overwrite (pattern-TP, needs a racing malicious spender), 3x governance
  ZeroAddress (`_setPendingAdmin`/`_setComptroller`/`_setInterestRateModel`),
  3x IntegerOverflow in the pure `fail()` error-formatting helper.
- Total: 2 CONFIRMED static-invisible findings across 4 protocols; both
  lending/money-market harnesses (credit-guild, compound-v2) clean. Analyzer
  untouched; pytest 21 passed / corpus 138/138 unaffected.

## Phase 3 sessions 7-8 (2026-08-04) — fifth protocol: hundred-finance HundredBond
- Harness `invariant_projects/hundred-bond/` (solc 0.8.0, optimizer runs=200,
  remapping `@openzeppelin/contracts/=src/`): vendored the Polygon variant
  `HundredBond.sol` (92 lines, `escrow_is_v2` constructor flag, `escrow.approve`
  in the v2 path) + OZ 4.4.1 deps; `test/Hnd.sol` (HND, 1M ether to the
  handler), `test/MockEscrow.sol` (veCRV-semantics: `locked`/`deposit_for`/
  `create_lock_for` pull from `msg.sender`), `test/HundredBondHandler.sol`
  (handler IS the bond owner, approves the bond once; 8 actors; ownerMint /
  actorBurn / actorRedeem / warp — all ERC20 flows, zero `.value()` cheatcodes,
  so the compound-v2 prank+value trap cannot recur), `test/Invariants.t.sol`,
  `test/Smoke.t.sol` (9 tests).
- 3 invariants (hndbIsBacked exact, hndbSupply exact, hndConservation == 1M
  ether): **ALL HOLD** at runs=200/depth=120 and runs=1000/depth=300 (300k
  calls per invariant, ~2.5k swallowed reverts each — expired-lock redeems /
  no-backing mints). 9/9 smoke tests pass, including `test_v1_redeem_always_reverts`.
- **Design findings (not protocol losses)**: (a) the **v1 escrow path
  (`escrow_is_v2=false`) makes `redeem()` always revert** against a
  veCRV-semantics escrow — `hnd.transfer(beneficiary, balance_)` moves the
  backing out of the bond, then `escrow.deposit_for` tries to pull the same
  amount from the bond with no `approve` (HundredBond.sol:65-66); (b) `burn`
  pays the **owner**, not the user, and once a user's escrow lock expires
  `redeem` reverts forever (no re-lock path through the bond) — early/late
  exit leaves the user's HND with the owner (design choice / UX fragility,
  not theft); (c) `rescueHnd` after 51 weeks drains the whole backing (by
  design; documented, not fuzzable).
- **run3 cross-check: `run3/hundred-finance.json` has 0 findings** — nothing
  to cross-check; the invariant suite is independent confirmation that the v2
  token accounting is sound.
- Total: 2 CONFIRMED static-invisible findings across 5 protocols
  (basis-cash, harvest-ousd); three clean high-value harnesses (credit-guild,
  compound-v2, hundred-bond). Analyzer untouched; pytest 21 passed / corpus
  138/138 unaffected.

## Phase 3 sessions 9-10 (2026-08-04) — sixth protocol: balancer-v2 Vault
- Harness `invariant_projects/balancer-v2/` (solc 0.7.6 binary pinned, evm
  istanbul): vendored the full `0xba1222...566bf2c8` Vault corpus (45 .sol
  files, ^0.7.0 + ABIEncoderV2) at `src/` with relative imports intact.
  Pure-ERC20 system: 3 MockERC20s (A/B/C), 2 constant-product MINIMAL_SWAP_INFO
  MockPools (A-B, B-C), permissive MockAuthorizer, 3 FlashLoanRecipients
  (repay / no-repay / under-repay), 8 actors (100k each token, max approval).
  `test/BalancerHandler.sol` routes swapGivenIn/Out, joinPool/exitPool,
  flashLoan, deposit/withdraw/transferInternal — every action via
  `vm.startPrank(actor)`/`stopPrank`.
- 8 invariants: token conservation (== 1M ether/token), **vault ledger**
  (vault physical balance == pool virtual cash + actor internal balances),
  pool-share conservation. **ALL HOLD** at runs=200/depth=120 and 1000/300
  (300k calls/invariant). 8/8 smoke tests pass.
- Root-caused this session: single-shot `vm.prank` is consumed by
  argument-evaluation calls (`pool.poolId()`) before the Vault call -> the
  test contract leaks as msg.sender (`BAL#503`); `startPrank`/`stopPrank`
  fixes it.
- **Teeth-check**: removing the `_increaseInternalBalance` line in
  `UserBalance.sol::_depositToInternalBalance` (Vault keeps the tokens, never
  credits the internal book) makes all 3 `vaultLedger_*` invariants FAIL (50
  low-run passes) while conservation stays green; restored -> green. The
  ledger invariant provably catches internal-balance accounting bugs.
- **run3 cross-check: all 19 balancer-v2 findings DISMISSED** (2 governance/
  constructor ZeroAddress + 13 IntegerOverflow on the guarded flashLoan /
  pool-balance / asset-transfer / swap-index paths + 2 TemporarilyPausable
  bounded-duration adds). Every flagged guarded path was exercised by the
  fuzzer (flashLoan ~37k calls with ~1.3k swallowed reverts = the no-repay/
  under-repay recipients hitting `BAL#515`; swaps/joins/exits/internal 0
  reverts) with the ledger+conservation invariants green throughout.
- Total: 2 CONFIRMED static-invisible findings across 6 protocols
  (basis-cash, harvest-ousd); four clean high-value harnesses (credit-guild,
  compound-v2, hundred-bond, balancer-v2). Analyzer untouched; pytest 21
  passed / corpus 138/138 unaffected.

## Phase 3 sessions 15-17 (2026-08-05) — ninth protocol: morpho-blue
- Harness `invariant_projects/morpho-blue/` (solc 0.8.19 pinned, evm paris,
  via_ir): vendored the full `0xbbbbbbbb...ffcb` `Morpho.sol` + interfaces +
  libraries verbatim at `src/core/` (no source edits). Two cross-token markets
  — A: USDC loan / WETH coll (2000 USDC/WETH, LLTV 86%, fee 10%), B: WETH loan
  / USDC coll (1/2000, LLTV 80%, fee 0) — on MockIrm (5% APR), MockOracle
  (price settable), MockERC20s; 8 actors (1M USDC + 1000 WETH), prank-based
  sender (all value ERC20, no `.value()` cheatcodes), low-level swallowed
  reverts (rocket-pool fuzzer-commit lesson). `MorphoHandler.sol` (12 fuzz
  actions incl. liquidate with oracle shocks to 0.001%–100% of honest price),
  `Invariants.t.sol` (10 invariants), `Smoke.t.sol` (8 tests),
  `Debug.t.sol` (shrunk counterexample replay).
- 10 invariants: supply-share conservation (actors + feeRecipient +
  address(0) — covers a zero fee recipient), borrow-share conservation,
  per-token no-leak balance-sheet (physical >= idle + counterpart collateral),
  **per-action ledger residual in {0,1}**, market solvency. **ALL HOLD** at
  runs=200/depth=120 and 500/300 (150k calls/invariant, 0 reverts). 8/8 smoke
  tests pass.
- **Found and root-caused Morpho's 1-wei repay dust**: the absolute
  balance-sheet identity is NOT exact — the virtual-share model
  (SharesMathLib VIRTUAL_SHARES=1e6) lets a repayment of the last borrow share
  compute `assets` one wei above `totalBorrowAssets`, overpaying 1 wei into the
  pool per full-book-share repay (Morpho.sol:290 comment). The gap accumulates
  over borrow→full-repay cycles (observed 2 wei), so no fixed tolerance is
  sound. Reformulated the ledger invariant as the exact per-action bound:
  each action may diverge physical vs book by at most +1 (never <0 = no value
  leak) — the `lastUsdcResidual`/`lastWethResidual` handler trackers. This is
  also precisely the `balanceOf`-delta discipline the run3 ValueFlow detector
  recommends.
- **run3 cross-check: all 7 morpho-blue findings DISMISSED.** ZeroAddress
  `setOwner`/`setFeeRecipient` are the documented governance-renouncement
  pattern (interface: "the owner can be set to the zero address"; smoke-pinned
  one-way door); ValueFlow supply/repay require fee-on-transfer tokens, which
  the interface explicitly excludes (and the residual invariant would catch the
  divergence); `liquidate` is permissionless by design; `setAuthorizationWithSig`
  is EIP-712 `ecrecover`-guarded (detector missed the sig-check pattern);
  `_accrueInterest` reentrancy is a read-only call to an owner-whitelisted IRM.
- **Echidna cross-check (session 17): all 10 properties passing.**
  `test/EchidnaMorphoBlue.sol` + `echidna.yaml` (testLimit 50000, seqLen 100,
  whitelist of the 12 fuzz actions). echidna 2.3.3 with crytic-compile 0.4.2
  (venv recreated at `/tmp/opencode/echidna_venv`) and solc 0.8.19 via
  solc-select (installed, added to `~/.solc-select/artifacts/`, global =
  0.8.19). 50234 calls, 0 failures, cov 14843 — the {0,1} per-action residual
  bound holds under echidna's byte-level fuzzing, matching the foundry 150k-call
  runs. Full output in `invariant_results.md`.
## Phase 3 sessions 18-19 (2026-08-05) — tenth protocol: compound-v3
- Harness `invariant_projects/compound-v3/` (solc 0.8.15 pinned to
  `/home/fatima/Downloads/static-analyzer/solc_versions/solc-0.8.15`, evm
  paris, via_ir): vendored `CometWithExtendedAssetList.sol` + CometCore/
  Configuration/Math/Storage/MainInterface + interfaces verbatim into
  `src/core/` (no source edits). Config: base USDC 6dp $1; collateral WETH 18dp
  $2000 (0.8/0.9/0.92) and WBTC 8dp $30000 (0.75/0.85/0.9); storeFront 0.5;
  kink 0.8; borrowPerYearInterestRateBase = 0.04e18 (makes
  `util*borrowRate >= supplyRate` everywhere — reserve growth structurally
  non-negative). 8 actors prefunded, prank-based sender, low-level swallowed
  reverts (`fail_on_revert = false`). `CometHandler.sol` (7 fuzz actions:
  supply, withdraw, transfer, absorb with oracle shocks, buyCollateral, pause,
  warp; no `_tick` between absorbs so absorb deltas are exact),
  `Invariants.t.sol` (7 invariants), `Smoke.t.sol` (7 tests).
- 7 invariants: base principal book (sum positives == totalSupplyBase, sum
  negatives == totalBorrowBase), WETH/WBTC collateral books, base no-leak
  (reserves + absorbedBadDebt >= 0), **per-action residual >= -DUST**,
  **absorb debt-bound (delta >= -(debtBefore + DUST))**, market solvency
  (balance + totalBorrow + absorbedBadDebt >= totalSupply). **ALL HOLD** at
  runs=200/depth=120 and 500/300 (150k calls/invariant, 0 reverts) on 4 seeds
  incl. the previously-failing seed; 7/7 smoke tests pass.
- **Root-caused three naive invariants into the real protocol behavior:**
  (1) `totalSupply() >= totalBorrow()` is NOT solvency — both are present-value
  views and the borrow index grows faster in the profitable case;
  (2) absorb can legitimately GROW reserves — collateral seized at the
  liquidation factor can over-cover a liquidatable debt (band between LiqF 0.9
  and ~1.02) and the surplus becomes a supply position, and the write-off can
  exceed the external `borrowBalanceOf` by 1 base unit (index/PV rounding);
  (3) non-absorb actions can move exactly 1 base unit of dust out of reserves
  via the principalValue/presentValue floor round-trip (Comet's 1-wei analog).
- **run3 cross-check: all 13 compound-v3 findings DISMISSED.** 9
  OracleManipulation/OracleTaint HIGH + 1 Timestamp LOW are the oracle-read
  surface: MockPriceFeed always returns updatedAt=1, price reads have no state
  effects, and the value-moving absorb/buyCollateral paths ARE the harness's
  shocked-price actions pinned by invariant_absorbAccounting / baseNoLeak /
  marketSolvent. 2 ZeroAddress are internal functions only reachable from
  governed/guarded external paths; 2 SignatureReplay are the delegatecall
  extension's signed allow (out of harness scope, EIP-712 nonce/deadline
  guarded); 1 is delegatecall-only extension storage (`isAllowed` never
  assigned in the main contract by design).
- Diagnostic instrumentation kept: `invariant_lastResidual` /
  `invariant_absorbAccounting` revert with `lastDelta`/`lastBound` (via the
  handler's `uint2str`) — only fires on a violation, exactly when the numbers
  matter; the `lastDelta`/`lastBound`/`lastIsAbsorb` handler trackers are the
  invariant inputs and stay.
- Total: 2 CONFIRMED static-invisible findings across 10 protocols
  (basis-cash, harvest-ousd); eight clean high-value harnesses (credit-guild,
  compound-v2, hundred-bond, balancer-v2, ionic-protocol, rocket-pool,
  morpho-blue, compound-v3) of which rocket-pool and morpho-blue pass echidna
  cross-checks; 18/18 run3 ionic findings verified + 7/7 + 3/3 + 19/19 + 13/13
  run3 morpho-blue/rocket-pool/balancer-v2/compound-v3 findings DISMISSED.
  Analyzer untouched; pytest 21 passed / corpus 138/138 unaffected.

## Phase 3 session 21 (2026-08-05) — twelfth protocol: kpk (Protocol 12, last of run3)
- Harness `invariant_projects/kpk/` (solc 0.8.24 pinned to
  `/home/fatima/Downloads/static-analyzer/solc_versions/solc-0.8.24`, evm paris,
  via_ir): vendored `kpkShares.sol` (1,145 lines) + `KpkOivFactory.sol` +
  `IkpkShares.sol` + FeeModules/ + interfaces/ + utils/ verbatim into `src/`,
  OZ v5.0.0 at `lib/` (pruned but semantically complete). **UUPS proxy**
  (ERC1967Proxy + `initialize` pranked as ADMIN; base USDC 6dp at $1, SAFE
  0x5000 with standing max allowance, MockPerfFeeModule, mgmt 5% / redemption
  1% / perf 2%, TTLs 1 day; `grantRole(OPERATOR)` + `updateAsset` WETH 18dp
  $3000 / SPARE 18dp as OPERATOR). `KpkHandler.sol` (6 actors, prank-based
  sender, low-level swallowed reverts, shadow request book + `staticcall`
  `getRequest` bias; 9 fuzz actions incl. processAction with ±10% settled-price
  band + rare 1/8 wild price), `Invariants.t.sol` (2 exact ledger identities),
  `Smoke.t.sol` (10 tests), `Debug.t.sol` (killed after green).
- 2 invariants: **shareBook** (`totalSupply == Σ balances` over vault escrow +
  fee receivers + actors) and **assetEscrow** (`asset.balanceOf(vault) ==
  subscriptionAssets[asset]` for all 3 assets). **BOTH HOLD** at runs=200/
  depth=120 and 500/300 (**150k calls/invariant**, 3 seeds: default, 1337, 42;
  ~11.5k swallowed reverts/run = the price-deviation / expiry / TTL guards).
  **10/10 smoke tests pass** (subscription+redemption roundtrips, TTL-gated
  cancels, expiry auto-reject, mgmt+perf fees exact, recover-assets incl.
  escrow gate, pricing floor round-trips, permission guards via expectRevert).
- **Pricing scale learned (differs from the naive read)**: shares = assets ×
  1e26/(price × 10^assetDec) via two mulDiv-Floor steps, so $1 @1e8 mints 1e24
  shares for 6dp base but 3 WETH @3000e8 → 1e15 shares (asset/shares decimals
  both 18 cancel). Fixing the smoke suite to this scale is what turned
  `RequestPriceLowerThanOperatorPrice` into green.
- **run3 cross-check: all 14/14 unique kpk findings DISMISSED** (56 total with
  4-chain dupes). Reentrancy HIGH at 1056 is the CEI-pattern `_updateAsset`
  (read-only `symbol()`/`decimals()` calls then `_approvedAssets.push`;
  operator-only, no callback receiver — updateAssetAction ran ~16k times with 0
  reverts); ValueFlow 231 is the transfer-in-then-ledger `+=` — the exact
  `assetEscrow` identity held across 150k calls (standard-ERC20 assumption,
  would catch fee-on-transfer divergence); ZeroAddress 217/665/772/799/1102/
  1141 are the init/admin param + request-struct classes (address(0) fails
  `NotAnApprovedAsset`, feeReceiver=0 mints to 0 = burn, perf module is an
  admin setter); Timestamp 269/383 are the intentional TTL gates
  (`RequestNotPastTtl`, LOW class — smoke-pinned, expiry auto-reject + cancel
  behavior verified); StorageCollision factory:76 / kpkShares:22 are the
  contract-declaration UUPS/inherited-storage class; IntegerOverflow OZ lib
  230/235 are `require(balanceOf>=amount)`-guarded.
- Total: **3 CONFIRMED static-invisible findings across 12 protocols**
  (basis-cash, harvest-ousd, monolith-market); **56/56 run3 kpk findings
  DISMISSED** → **142/142 run3 findings DISMISSED across the 9 harnessed
  finding-bearing protocols** + 18/18 ionic CONFIRMED. Analyzer untouched;
  pytest 21 passed / corpus 138/138 unaffected.

## Phase 3 session 20 (2026-08-05) — eleventh protocol: monolith-market
- Harness `invariant_projects/monolith-market/` (solc 0.8.13 pinned to
  `/home/fatima/Downloads/static-analyzer/solc_versions/solc-0.8.13`, evm
  paris, via_ir): vendored Lender/Vault/Factory/Coin/InterestModel + solmate
  verbatim into `src/` (no source edits). Factory operator is `0x2000` (a
  distinct account, constructor-set), lender operator actors[0], fee recipient
  actors[1]; the 1% factory fee is set BEFORE `factory.deploy` (the Lender
  caches `cachedGlobalFeeBps` only at construction + on a successful
  `accrueInterest`). `MonolithHandler.sol` (6 actors, prank-based sender,
  low-level swallowed reverts; 19 fuzz actions incl. liquidate with 0.1%–100%
  price shocks, redeem, attemptWriteOff, vault ERC4626 actions, shockPrice
  incl. stale 26h–3d feed, warp to 365d, fee/ratio/half-life setters, local+
  global reserve pulls), `Invariants.t.sol` (5 invariants), `Smoke.t.sol`
  (8 tests).
- 5 invariants (exact ledger identities): coinLedger
  (supply == freeDebt + paidDebt − localReserves − globalReserves),
  paidSharesConserved, vaultSharesConserved (MIN_SHARES dead-share book),
  vaultCovered, lenderHoldsNoCoin. **4/5 HOLD** at runs=200/depth=120 and
  500/300 (150k calls/invariant, 0 reverts, seeds 42/1337); **8/8 smoke pass**.
- **CONFIRMED finding #3 (HIGH, ledger unbacking): `Lender.writeOff` on the
  sole remaining debtor deletes debt without burning Coin.** writeOff is
  permissionless; it deletes the borrower's debt then redistributes it to the
  remaining debtors ONLY `if (totalDebt > 0)` (Lender.sol:318) — when the
  target is the last debtor the debt vanishes with no Coin burn, permanently
  breaking `supply == debt − reserves`. Deterministic 2-call counterexample
  (`combinedBorrow` → `attemptWriteOff`): after ~30h of staleness (inside the
  49h unwind window `getCollateralPrice` decays the price while leaving
  `allowLiquidations` true) a single borrower's 5.768e26 Coin debt is deleted
  with supply unchanged → all Coin unbacked. Also reachable via a >99% price
  collapse in a single-borrower market. NOT in run3.
- **run3 cross-check: all 26 monolith-market findings DISMISSED** (9
  Reentrancy HIGH = CEI-pattern flags on pure accounting / standard-ERC20
  transfers / order-smell reserve pulls with no reentry vector; 5 AccessControl
  HIGH = permissionless-by-design deposit/mint/redeem/liquidate; 7 ZeroAddress
  = constructor + operator-setter inputs; 2 FrontRunning + 1 MEV = approve
  overwrite and oracle-less ERC4626; 2 ValueFlow = fee-on-transfer assumption
  on protocol-own ERC20s). The harness exercised every flagged function
  thousands of times with the exact ledger identities green — none corresponds
  to the writeOff bug.
- Harness robustness: at extreme interest-inflated debt (fast half-life +
  long warps) the protocol's own `getDebtOf`/`getRedeemAmountOut` overflow
  (solmate mulDivDown, shares×debt > 2^256), so the handler try/catch-wraps
  those reads (never-revert discipline); documented as a low availability note.
- Total: **3 CONFIRMED static-invisible findings across 11 protocols**
  (basis-cash, harvest-ousd, monolith-market); eight clean harnesses; **18/18
  run3 ionic findings CONFIRMED** + **116/116 run3 findings across the other 8
  harnessed protocols DISMISSED**. Analyzer untouched; pytest 21 passed /
  corpus 138/138 unaffected.

## Phase 3 — campaign complete (2026-08-05, after session 21)
- Final REPORT.md addenda #7-#12 written (ionic, rocket-pool, morpho-blue,
  compound-v3, monolith, kpk). All 12 sessions committed + pushed to
  `origin/release-0.2` (HEAD `4ca58b2`). Optional kpk echidna cross-check
  declined (foundry 150k-call/3-seed corroboration deemed sufficient).
- Campaign outcome across 12 harnessed protocols: **3 CONFIRMED
  static-invisible protocol bugs** (basis-cash Boardroom phantom rewards,
  harvest-ousd yield-delegation fund-lock, monolith writeOff unbacking — all
  fund-lock/accounting breakage, none exploitable for theft); **142/142 run3
  findings DISMISSED** across the 9 harnessed finding-bearing protocols
  (credit-guild 41, compound-v2 7, balancer-v2 19, rocket-pool 3, morpho-blue
  7, compound-v3 13, monolith 26, kpk 56; harvest 5 cross-checked in session
  2) and **18/18 run3 ionic findings CONFIRMED** (all MEDIUM, owner-only
  zero-address setters + latent upgrade hazard).
- Analyzer untouched throughout; pytest 21 passed / corpus 138/138 every
  session. The invariant harnesses are now the counterbalance to the static
  run: they both dismiss the detector FPs at scale and surface the control-
  flow/edge-case bugs static patterns cannot see.



- Consider a run-once/flag guard (`require(once)` + write-after-call) nuance for
  the basis-cash distributors, or accept as low-severity findings.
- Decide whether the 3 remaining CEther `requireNoError` IntegerOverflow
  findings (pure error helper: `length+5`, `48+errCode/10`, `48+errCode%10`)
  should be suppressed too. NOTE: any pure-function suppression must be
  re-verified against the corpus before shipping (recall risk).
- Optional future: a "pure/view function" exemption in the ranker to de-skew
  no-guard signals on non-attackable reads (lido isValidBump class).


## Slither corpus campaign (2026-08-14)
- Ran slither-analyzer 0.11.6 (default detectors, all impact levels, --fail-none) over the 1,574-protocol TVL corpus (1,600 address-dirs). Final run `slither_2026_08_14_final`: 1,584 OK / 11 VYPER / 16 FAIL (~99%). 3 of the 16 FAIL rows are stale `.sanitized` pseudo-dirs (artifacts of sanitize_tree; run script now excludes them) -> 13 unique real FAILs, mostly unfixable (solc stack-too-deep, Slither ternary limitation, missing OZ sources, tload/mcopy vs pinned solc).
- Tooling added: `tools/slither_worker.py` (per-import full-path solc remaps, space-separated; --allow-paths; Etherscan JSON-blob extraction; sanitize_tree; Vyper detection; --via-ir retry) + `run_slither_corpus.sh`. Run history: v1 86.2%/42,666 findings, v2 93.7%/47,891, v3 97.75%, final ~99%.
- Pipeline work committed to TVL repo: address-discovery fix (01_defillama.py), metadata crash fix (02_metadata.py), export_deployments_csv.py.
- NEXT: triage High-impact findings (aggregate top_findings.tsv by detector + protocol, produce protocol-level report).
