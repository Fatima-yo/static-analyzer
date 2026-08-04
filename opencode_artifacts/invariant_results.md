# Phase 3 — Invariant testing results

Date: 2026-08-04 (Phase 3 sessions 1–2)

## Protocol 1: basis-cash (Boardroom reward accounting)

Harness: `invariant_projects/basis-cash/`
- `test/BasisCashHandler.sol` — standalone solc 0.6.12 handler (no forge-std):
  operator-of-cash/share/boardroom, 8 actors seeded with 100,000 BAS each,
  fuzzable `actorStake` / `actorWithdraw` / `actorClaim` (pranked per-actor),
  `allocateSeigniorage` (mints bounded BAC, mirrors Treasury's cash push),
  `warpDays`. Every action rolls the block AND warps +12s so the Boardroom's
  `onlyOneBlock` guard and timestamp-based reward eligibility behave like real
  chains (a constant timestamp makes every staker retroactively earn from all
  snapshots — a harness artifact, not a protocol bug).
- `test/Invariants.t.sol` — `BasisCashInvariants`; targets the handler via the
  StdInvariant getter ABI (`targetContracts`/`targetSenders`); three invariants.

Invariants:
1. `invariant_earningsNeverExceedAllocated` — sum(pending claims) + already
   claimed <= total seigniorage allocated. **VIOLATED (CONFIRMED finding).**
2. `invariant_noRewardWithoutStake` — zero shares => zero earnings. HOLDS.
3. `invariant_shareBooksBalance` — actors + boardroom share balances == total
   supply. HOLDS.

Tooling notes (foundry 1.7.1 + solc 0.6.12):
- `assert(false)` in Solidity 0.6.x compiles to the INVALID opcode, which
  Foundry reports as the opaque `EvmError: InvalidFEOpcode`. Use
  `require(cond, "message")` in invariant bodies for readable reports.
- Public (fuzzable) `setUp`-style helpers must be made internal; forge treats
  every public handler function as a fuzz target and will re-initialize state
  mid-run.
- `allocateSeigniorage` pulls cash from the operator via `transferFrom`, so the
  handler must approve the boardroom first.

### CONFIRMED finding (MEDIUM): Boardroom phantom/retroactive reward inflation

- Location: `src/contracts/Boardroom.sol` — `withdraw()` (line ~129),
  `stake()` (line ~110), `getCashEarningsOf()` (line ~76).
- Mechanism: `stake`/`withdraw` rewrite the *most recent* `BoardSnapshot.totalShares`
  (Boardroom.sol:123/145). `getCashEarningsOf` divides each snapshot's
  `rewardReceived` by that snapshot's `totalShares` at claim time. So when a
  director exits, the claim computed at exit time is paid, and the remaining
  directors' claims for the *same* reward are retroactively recomputed against
  the reduced `totalShares` — inflating them. The sum of all claims
  (paid + pending) can exceed the cash the boardroom actually holds.
- Concrete trace (from `test/Findings.t.sol::test_phantomRewardOnWithdraw`):
  1. A and B each stake 100 shares.
  2. Treasury allocates 100 BAC (snapshot: reward=100, totalShares=200).
  3. B exits fully; B's claim = 100*100/200 = 50 (paid); snapshot
     `totalShares` rewritten 200 -> 100.
  4. A's pending = 100*100/100 = 100, but boardroom holds only 50 BAC.
     A's `claimDividends()` (and therefore any `withdraw`) **reverts**.
- Fuzzer counterexample (shrunk to 4 calls, reproduced across 200 and 1000
  runs, and with multiple seeds):
  `actorStake(1, x)` -> `actorStake(0, y)` -> `allocateSeigniorage(z)` ->
  `actorWithdraw(1, w)` fails `invariant_earningsNeverExceedAllocated`.
- Impact: late claimers (and anyone whose withdraw triggers `claimDividends`)
  are locked — DoS / stuck funds. Not direct theft: an early exit claims a
  fair share; the remaining directors simply cannot claim more than the
  boardroom holds. The protocol loses no value, but users' stake becomes
  unrecoverable without a new allocation.
- Class: reward-contract accounting ("reward claim after exit" / retroactive
  dilution). This is invisible to the static analyzer (no Boardroom findings
  in run3) — a cross-function arithmetic property that invariant testing is
  uniquely suited to catch.

### Secondary note (low, not confirmed as realistic): zero-totalShares div-by-zero
- `allocateSeigniorage` with zero directors creates a snapshot with
  `totalShares = 0`; `getCashEarningsOf` then divides by it. In practice the
  SafeMath div-by-zero only triggers if deployment, a zero-staker allocation,
  and the first stake all share the same block timestamp AND the eligibility
  break (`snapshot.timestamp < appointmentTime`) is bypassed — an unrealistic
  same-block coincidence under the protocol's `onlyOneBlock` guard. The harness
  guards `allocateSeigniorage` when `totalShare() == 0` to keep the fuzzer on
  the reward-conservation path; the unprotected path is documented here only.

## Cross-reference with run3 static findings (basis-cash, 45 findings)
- The static analyzer's basis-cash findings are AccessControl / Reentrancy /
  ZeroAddress / Timestamp / ValueFlow (staking `safeTransferFrom` atomicity,
  DISMISSED in Phase 2). None touch Boardroom accounting.
- The invariant testing CONFIRMS one new, static-invisible accounting flaw and
  refines the Phase 2 null result: static HIGHs were all dismissed, but
  invariant testing finds a real fund-lock DoS the analyzer never flagged.

## Status
- basis-cash invariant harness complete and committed. Finding documented.
- Next: second protocol (harvest-finance or compound-v2) with the same
  handler+invariant pattern.

---

## Protocol 1 cross-check: Echidna on the basis-cash harness (session 2)

Setup: echidna 2.3.3 (`~/.config/.foundry/bin/echidna`) + `crytic-compile`
(0.4.2) in a dedicated venv (`/tmp/opencode/echidna_venv`). solc 0.6.12 wired
into `solc-select` (`~/.solc-select/artifacts/solc-0.6.12/solc-0.6.12`) because
crytic-compile prefers solc-select's global version over PATH.

Harness additions:
- `test/EchidnaBasisCash.sol` — composition wrapper over `BasisCashHandler`;
  forwards the 5 fuzz actions and exposes 3 `echidna_*` view properties.
- `echidna.yaml` — `testMode: property`, `testLimit: 50000`, `seqLen: 100`,
  `filterBlacklist: false` with an explicit whitelist of the 5 action
  functions (inherited-function names are matched by the derived contract name).

Cheatcode support verified empirically before the campaign: echidna 2.3.3
honors Foundry's `prank`, `startPrank`, `stopPrank`, `warp`, `roll` at address
`0x7109709ECfa91a80626fF3989D68f67F5b1DD12D` (a probe contract confirmed each).

Results (two seeds):
- `echidna_earnings_never_exceed_allocated`: **FAILED** — independent
  reproduction of the same Boardroom phantom-reward finding. Seed A shrunk to
  the identical 4-call shape as foundry:
  `actorStake(0,1) -> actorStake(1,1) -> allocateSeigniorage(2) ->
  actorWithdraw(0,1)` (pending=2 + claimed=1 > allocated=2). Seed 12345 also
  falsified it with a longer unshrunk sequence.
- `echidna_no_reward_without_stake` and `echidna_share_books_balance`:
  **passing** (50k tests / 100-deep sequences).

Conclusion: two independent fuzzers (foundry 1.7.1 invariant mode and echidna
2.3.3) agree on the same confirmed finding. No divergence.

---

## Protocol 2: harvest-finance OUSD (elastic-supply rebasing token)

Harness: `invariant_projects/harvest-ousd/`
- Vendored from the run1 `full_code` harvest snapshot
  (implementation `0xd86756...`): `src/contracts/token/OUSD.sol` +
  `interfaces/IVault|IStrategy|IBasicToken`, `vault/VaultStorage.sol`,
  `governance/Governable.sol`, `utils/Initializable|Helpers.sol`, and the OZ
  deps (SafeCast, SafeERC20, IERC20, Address). solc 0.8.28, remapping
  `@openzeppelin/=src/openzeppelin/`.
- `test/HarvestHandler.sol` — `OUSDHarness is OUSD` (exposes the `internal`
  `creditBalances`/`alternativeCreditsPerToken` maps and `_setGovernor`; the
  `private` `rebasingCredits_` is read via the public high-res getter) plus a
  handler that is simultaneously the initial **governor** and the **vault**
  (mint/burn/changeSupply role), with 8 EOA actors and fuzzable actions:
  `actorTransfer`, `actorTransferFrom`, `vaultMint`, `vaultBurn`,
  `vaultChangeSupply` (target in [cur/2, 1.5·cur]), `actorRebaseOptIn/Out`,
  `governanceRebaseOptIn`, `delegateYield`, `undelegateYield`, `warpDays`.
- `test/Invariants.t.sol` — `HarvestInvariants` (StdInvariant getter ABI, 8
  senders) with four invariants; `test/Smoke.t.sol` — 7 deterministic round-trip
  tests; `test/Findings.t.sol` — 2 deterministic repros.

Invariants:
1. `invariant_sumBalancesLeSupply` — sum(balanceOf(actors)) <= totalSupply.
   **VIOLATED (via revert; CONFIRMED finding below).**
2. `invariant_creditsConservation` — rebasingCredits_ == sum(creditBalances of
   altCreditsPerToken==0 accounts). HOLDS (200 and 1000 runs).
3. `invariant_nonRebasingConservation` — nonRebasingSupply == sum(balances of
   StdNonRebasing accounts). HOLDS.
4. `invariant_nonRebasingLeSupply` — nonRebasingSupply <= totalSupply. HOLDS.

### CONFIRMED finding (MEDIUM, fund-lock DoS): yield delegation + negative rebase underflows the target

- Location: `src/contracts/token/OUSD.sol` — `delegateYield()` (lines 632-694),
  `balanceOf()` (lines 182-196), `changeSupply()` (lines 597-626).
- Mechanism: `delegateYield` folds the source's credits into the target
  (`creditBalances[target]` = combined, OUSD.sol:674-677) and FREEZES the
  source's credits at its delegation-time balance (OUSD.sol:684-685). For a
  YieldDelegationTarget, `balanceOf` = rebased-combined - frozen-source-credits
  (OUSD.sol:191-194). A negative rebase (`changeSupply` shrink) raises
  `rebasingCreditsPerToken_`; when the rebased combined value drops below the
  frozen source credits, the subtraction underflows (panic 0x11) and every
  `balanceOf`/`transfer`/`transferFrom` on the target reverts — the delegated
  account is locked.
- Threshold: with a 2-account delegation (source=target=100,000 OUSD, cpt 1e27),
  underflow starts when totalSupply < ~400,000 OUSD (cpt > 2e27).
- Fuzzer counterexample (shrunk to 3 calls): `actorTransferFrom(...) ->
  delegateYield(0,238) -> vaultChangeSupply(4)`. Cleaner deterministic repros in
  `test/Findings.t.sol`:
  - `test_yieldDelegationNegativeRebaseLocksTarget`: delegate actor4->actor2,
    actor6 opts out, halve supply (vaultChangeSupply(1228)); source keeps
    100,000 OUSD (fully insulated), target's `balanceOf` reverts and a 1-wei
    transfer from the target reverts too.
  - `test_yieldDelegationDoubleHalveLocksTarget`: delegate + two halvings, no
    opt-out needed (cpt 1e27 -> 2e27 -> 4e27 crosses the threshold).
- Impact: the delegation target's account is bricked (funds locked) and the
  negative rebase is absorbed asymmetrically (source keeps full value, target
  bears the entire loss) — an accounting asymmetry, not just a rounding edge.
  Requires a governor-initiated delegation plus a large (>~50% combined)
  negative rebase, or repeated smaller shrinks.
- Class: elastic-supply accounting. Invisible to static analysis: run3 flagged
  only the `_adjustAccount` reentrancy angle (borderline FP) and never the
  rebase-vs-delegation arithmetic. A second static-invisible confirmed finding.

### Harness note (reported for completeness, not exploitable)
- `changeSupply` reverts when `_newTotalSupply <= nonRebasingSupply`
  (`totalSupply - nonRebasingSupply` underflow) or when `rebasingSupply == 0`
  makes `(credits*1e18 + rebasingSupply - 1)` underflow. The production Vault
  computes backing >= non-rebasing supply, so this is a defensive bound; the
  handler guards `target <= nonRebasingSupply`.

## Cross-reference with run3 static findings (harvest, 5 findings)
- run3 harvest findings: `approve` allowance-overwrite (genuine, known
  SWC-114) and `_adjustAccount` reentrancy (borderline FP — internal read-only
  chain, no external value transfer). Neither is what invariant testing found.
- The confirmed OUSD finding is a **third distinct issue class** (rebase /
  delegation accounting) entirely outside the static detector's view.

## Status (session 2)
- basis-cash: foundry + echidna agree on the Boardroom finding.
- harvest-ousd: harness complete; 3/4 invariants HOLD at 1000 runs; the
  delegation/negative-rebase finding confirmed with 2 deterministic repros.
- Next: third protocol harness (balancer-v2, compound-v2, or credit-guild), or
  an echidna pass over harvest-ousd.

---

## Protocol 3: credit-guild (Ethereum Credit Guild lending loop) — sessions 3-4

Harness: `invariant_projects/credit-guild/`
- Vendored from the run1 full-code snapshot (`full_code/credit-guild/
  Arbitrum_42161/0xb8ae64f...`): `src/core/Core{,.s}ol`,
  `src/tokens/{CreditToken,GuildToken,ERC20Gauges,ERC20MultiVotes,
  ERC20RebaseDistributor}.sol`, `src/governance/ProfitManager.sol`,
  `src/loan/{LendingTerm,AuctionHouse}.sol`, `src/rate-limits/
  RateLimitedMinter.sol`, OZ deps. solc 0.8.13, evm london, optimizer
  runs=200; remappings `@openzeppelin/contracts/=`, `@src/=`.
- `test/CreditGuildHandler.sol` — full ECG wiring: handler is Core
  default-admin + GOVERNOR + gauge roles; ProfitManager gets CREDIT_MINTER/
  BURNER (it mints/burns CREDIT when settling PnL — an easy wiring detail to
  miss, surfaced by the smoke suite). Two `LendingTerm` EIP-1167 clones (the
  implementation constructor bakes `core=address(1)` and `initialize` asserts
  the proxy slot is 0, so direct deploys are impossible). LendingTerms hold
  GAUGE_PNL_NOTIFIER + CREDIT_MINTER/BURNER + RATE_LIMITED_CREDIT_MINTER;
  `RateLimitedMinter` additionally holds RATE_LIMITED_CREDIT_MINTER.
  `guild.setMaxGauges(10)` (default 0 makes every `incrementGauge` revert);
  `gaugeWeightTolerance` raised 1.2e18 -> 2e18 so a balanced 50/50 gauge
  split doesn't cap every 2nd borrow at 60% of total issuance (dead fuzz
  weight). 8 actors, 25k GUILD to each term (50/50), 100k CREDIT / 1M
  collateral each, all rebasing.
- Actions (each rolls block + warps +12s): borrow / addCollateral /
  partialRepay / repay / call / bid / forgive / donateSurplus / increment/
  decrementGauge / transferCredit / transferGuild / transferCollateral /
  applyGaugeLoss / claimRewards / enterExitRebase / warpDays.
- `test/Invariants.t.sol` — `CreditGuildInvariants`, 7 invariants:
  creditConservation (sum of all protocol-held + actor balances == supply
  within rebase rounding), guildConservation, gaugeWeightConservation
  (user-sums == gauge weights; live == totalWeight/typeWeight; per-user
  totals == sum), votesConservation (delegated == received),
  collateralConservation (term balances == open-loan collateral + forgiven
  stuck collateral), issuanceConsistency (ProfitManager ledger == terms),
  issuanceWithinCaps.
- `test/Smoke.t.sol` — 9 deterministic round-trips that pin the exact
  protocol transitions and would have caught every wiring bug below.

### Result: ALL 7 INVARIANTS HOLD
- Green at default runs=200/depth=120 (~10s), at `--fuzz-runs 1000`, and at a
  stressed runs=1500/depth=200 (~117s, config restored after). The fuzzer
  reaches every action surface: over 1300 actions/run with ~15% borrowing and
  every other action exercised. No invariant violation found.
- This is the strongest signal yet for the lending loop: CREDIT/GUILD/
  collateral/gauge-weight accounting, the PnL path (call -> auction -> bid /
  forgive -> notifyPnL -> surplus buffer burn + creditMultiplier), and
  issuance ledgers are all self-consistent under adversarial randomized
  sequences. `fail_on_revert=false` keeps revert-heavy actions (e.g. calling
  a healthy loan) from polluting the checks.

### Smoke-suite wiring findings (fixed; protocol worked as intended)
1. `LendingTerm` cannot be deployed directly (constructor bakes
   `core=address(1)`); the hand-rolled solmate-style assembly clone silently
   deploys zero-byte code under solc 0.8.13 — used the verified
   bytes.concat EIP-1167 (55-byte) form instead.
2. `ERC20Gauges.maxGauges` defaults to 0 -> every `incrementGauge` reverts
   "exceed max gauges"; fixed with `setMaxGauges(10)`.
3. ProfitManager needs CREDIT_MINTER + CREDIT_BURNER on the core: `notifyPnL`
   loss path burns the surplus buffer; without the role the burn reverts
   UNAUTHORIZED and the whole PnL settlement silently rolls back.
4. `gaugeWeightTolerance` default 120% + 50/50 gauge split caps each term at
   60% of total issuance: a 2nd loan on the same term always reverts "debt
   ceiling reached" (dead fuzz weight). Raised to 200% in the harness.
5. Protocol semantics that the smoke tests initially encoded wrong:
   `call()` sets `callTime`, NOT `closeTime` (loan closes only at `onBid`);
   `partialRepay` requires remaining principal > `ProfitManager.minBorrow()`
   (100e18) — a 100e18 loan can never be partially repaid;
   `forgive` requires the auction to have fully elapsed (creditAsked -> 0);
   `warpDays` caps at 30 days per call (`%31`); the surplus buffer is a
   loss-absorber, NOT a donor-reclaimable pool — `claimRewards` never pays a
   donor back (assertion corrected).

### Cross-reference with run3 static findings (credit-guild, 41 findings)
- HIGH Reentrancy x10 (ERC20Gauges x7, ERC20MultiVotes x3): **DISMISSED** —
  flagged lines are internal pure state accounting (`_incrementGaugeWeight`,
  `_decrementGaugeWeight`, `_undelegate`, `_writeCheckpoint`); no external
  calls to untrusted code (the analyzer over-approximates `emit`/hook calls).
  Empirically consistent with the gauge/votes conservation invariants holding
  across every increment/decrement/transfer/applyGaugeLoss sequence.
- HIGH Timestamp x2 (ProfitManager:204, LendingTerm:450) + MEDIUM/LOW
  Timestamp x8 (AuctionHouse, LendingTerm, ERC20MultiVotes,
  ERC20RebaseDistributor): **DISMISSED** — `block.timestamp` is the protocol's
  designed clock for interest accrual, auction phase timing, partial-repay
  delays, and gauge-loss application deadlines; none is randomness for a
  security-critical draw.
- MEDIUM BadRandomness LendingTerm:459: **DISMISSED** —
  `loanId = keccak256(abi.encode(borrower, term, block.timestamp))` is an
  identifier, not lottery randomness; predictability of loan IDs is not
  exploitable.
- MEDIUM AccessControl ERC20RebaseDistributor:342 (`distribute`): **DISMISSED**
  — permissionless by design: it burns the caller's own tokens and distributes
  them proportionately to rebasing accounts.
- MEDIUM StorageCollision x5 (ProfitManager, LendingTerm, CreditToken,
  GuildToken, EIP712/CoreRef via inheritance): **DISMISSED** — standard
  multi-inheritance linearization; the EIP-1167 clones run the implementation's
  layout on their own storage and all state reads are consistent (the whole
  invariant suite runs on those clones).
- MEDIUM IntegerOverflow x3 (OZ ERC20 + ERC20RebaseDistributor): **DISMISSED**
  — solc 0.8.13 arithmetic panics on overflow; no unchecked blocks.
- MEDIUM Uninitialized EIP712 x2 / ZeroAddress CoreRef x2 / RateLimitedMinter
  x4 / FrontRunning+MEV x5: **DISMISSED** — constructor-perm-configuration and
  governance-bound rate-limit settings (e.g. zero-address core set at deploy,
  rate limit governance-settable), no attacker-reachable impact.
- **No credit-guild run3 finding was confirmed.** The lending-loop invariants
  holding at scale is independent corroboration that the 10 reentrancy and 2
  timestamp HIGHs are analyzer false positives.

## Status (session 4)
- basis-cash: Boardroom phantom-reward finding CONFIRMED (foundry + echidna).
- harvest-ousd: yield-delegation/negative-rebase finding CONFIRMED.
- credit-guild: full lending-loop harness GREEN (7/7 invariants at 200, 1000,
  and 1500 runs; 9/9 smoke tests). No new finding; run3 findings cross-checked
  (all dismissed).
- Total: 2 CONFIRMED static-invisible findings across 3 protocols; credit-guild
  is the first full high-value harness with a clean result.
- Next: 4th protocol (balancer-v2 / compound-v2), or an echidna pass over
  harvest-ousd / credit-guild.
