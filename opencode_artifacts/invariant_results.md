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

## Protocol 4: compound-v2 (CEther money market) — sessions 5-6

Harness: `invariant_projects/compound-v2/`
- Vendored from the run1 full-code snapshot (`full_code/compound-v2/
  Ethereum_1/0x4ddc2d193948926d02f9b1fe9e1daa0718270ed5/CEther.sol`), flattened
  to a single self-contained file. solc 0.5.8, evm istanbul, optimizer runs=200.
  The 0.4.x CToken has no external imports and a public constructor, so it
  compiles as-is (the last two protocols both needed EIP-1167 workarounds; this
  one just worked).
- `src/SimpleComptroller.sol` — permissive comptroller: every policy hook
  (mint/borrow/redeem/repay/liquidate/seize/transfer) returns NO_ERROR,
  `getUnderlyingPrice` = 1e18 for both markets, liquidation incentive 1.08e18,
  and a faithful `liquidateCalculateSeizeTokens` with the exchange-rate-zero
  guard and the `seizeShares < amount` consistency re-check.
- `src/SimpleInterestRateModel.sol` — White-Paper rate model (baseRate 5e12,
  multiplier 4.95e14) whose `getBorrowRate` never hits the borrow-rate cap, so
  `accrueInterest` always succeeds.
- `test/Actor.sol` + `test/CompoundV2Handler.sol` — **real on-chain Actor
  contracts** (see "Foundry prank+value bug" below) each owning 1M ETH, plus a
  handler that routes 8 actions (mint / redeem / borrow / repay / repayBehalf /
  liquidate / transfer / transferFrom) plus `warpBlocks` through them. Each
  successful action rolls the block so `accrueInterest` sees a positive delta.
  Two CEther markets (cethA/cethB) at initial exchange rate 0.02e18. Action
  clamps: mint/repay to balance, borrow to market cash, repay to debt, redeem
  to holdings, transfer to balance; liquidations skip same-market
  (nonReentrant guard) and over-seize (borrower lacks the collateral tokens the
  seize would need) cases.
- `test/Invariants.t.sol` — `CompoundV2Invariants`, 3 invariants:
  ctokenConservation (totalSupply == sum of holder balances, exact),
  ethConservation (actors + both markets + handler == 8e24, exact),
  borrowLedger (sum of per-account `borrowBalanceStored` == `totalBorrows`,
  within 1e9 wei per-account truncation).
- `test/Smoke.t.sol` — 9 deterministic round-trips: mint/redeem round-trip,
  mint/borrow/repay loop, capped-repay solvency, interest accrues across
  blocks, transfer/transferFrom, two liquidation tests (repaid ledger delta is
  principal minus a block's accrued interest; seized collateral bounded by the
  1.08 incentive at the 0.02 exchange rate), and a mixed stress sequence that
  must end with all three invariants holding.

### Result: ALL 3 INVARIANTS HOLD
- Green at default runs=200/depth=120 (~4s), at invariant runs=1000/depth=120
  (~20s), and at `--fuzz-runs 5000`; 9/9 smoke tests pass. The fuzzer reaches
  every action surface (24k calls/run with zero handler-level reverts), and the
  ETH conservation invariant (which a real cToken harness would flag if any
  action leaked or misdirected underlying) holds exactly across ~100k+ mint/
  borrow/repay/redeem/liquidate operations.
- No protocol flaw surfaced: CEther's ETH accounting, cToken supply math,
  accrual, and the seize/liquidate path are internally consistent under
  adversarial randomized sequences.

### Foundry prank+value bug (the real find of this session)
The first handler called the markets via `vm.startPrank(actor)` +
`c.mint.value(x)()` (high-level cheatcode-pranked value calls). Under the
invariant fuzz runner (real-tx sender + inner prank) exactly one full actor
balance (1e24) vanished on a reverting value call: conservation broke by 1e24
with the handler's own post-action check (`broken`) never firing because the
revert bubbled out of the whole handler call before `_tick`. Hand-written
replays of the shrunken counterexample passed every time (direct / outer-prank
/ low-level-call-with-swallowed-reverts), so the loss is fuzz-context-only:
foundry's prank balance redirection interacts badly with high-level `.value()`
calls that revert. The fix was architectural — **real Actor contracts** that own
their ETH and call the markets as ordinary atomic EVM transfers, eliminating
every value-carrying cheatcode — after which conservation went green and the
smoke suite confirmed value actually moves (a low-level `.call.value()`-from-a-
0-balance-handler variant silently did nothing under fuzz and was rejected by an
activity invariant before being replaced).

### Cross-reference with run3 static findings (compound-v2, 7 findings)
- FrontRunning CEther.sol:1131 (`approve` overwrites allowance, SWC-114):
  **DISMISSED (pattern-TP)** — real known Compound pattern but requires a
  malicious spender racing a legitimate transaction; not a protocol flaw, and
  the transfer/transferFrom/approve loops in the harness stayed consistent.
- ZeroAddress x3 (`_setPendingAdmin`, `_setComptroller`, `_setInterestRateModel`)
  and IntegerOverflow x3 (error-formatting `+` and `fail()` index arithmetic):
  **DISMISSED (baseline/noise)** — constructor/governance configuration and
  pure formatting helpers, none on any value path exercised by the harness.
- **No compound-v2 run3 finding was confirmed**, consistent with all three
  invariants holding across the money-market loop.

## Protocol 5: hundred-finance HundredBond — sessions 7-8

Harness: `invariant_projects/hundred-bond/`
- Vendored from the run1 full-code snapshot (`full_code/hundred-finance/
  Polygon_137/0x636b5b572e5b6869d9d72124ebb67eca0babcaea/contracts/
  HundredBond.sol`, the 92-line Polygon variant) + OZ 4.4.1 deps. solc 0.8.0,
  optimizer runs=200, remapping `@openzeppelin/contracts/=src/`.
- `test/Hnd.sol` — HND governance token, 1M ether minted to the handler (the
  single accounting sink that every conservation invariant is measured
  against). `test/MockEscrow.sol` — a veCRV-semantics `IVotingEscrow` mock:
  `create_lock_for` (first lock, requires `end > now`) and `deposit_for`
  (requires an existing lock) each pull `_value` HND from `msg.sender` (the
  bond, which approves in the v2 path) via `transferFrom`.
- `test/HundredBondHandler.sol` — the handler deploys HND -> MockEscrow ->
  HundredBond so it is the bond's **owner** (owns all HND, approves the bond
  once for `type(uint256).max`); 8 actor addresses; fuzzable `ownerMint`
  (clamped to the owner's HND backing), `actorBurn` (clamped to the actor's
  HNDb), `actorRedeem`, `warp` (cap 200 weeks so the mock's int128 lock
  amounts can never approach their bound). All value flows are plain ERC20
  `transferFrom`/`transfer` — there are **zero `.value()` cheatcodes**, so
  the compound-v2 prank+value revert leak cannot recur by construction.
- `test/Invariants.t.sol` — `HundredBondInvariants` (StdInvariant getter ABI,
  8 senders) with three invariants; `test/Smoke.t.sol` — 9 deterministic tests.

Invariants:
1. `invariant_hndbIsBacked` — `hnd.balanceOf(bond) == bond.totalSupply()`
   (every HNDb outstanding is backed 1:1 by HND sitting in the bond). HOLDS.
2. `invariant_hndbSupply` — `totalSupply == sum of the 8 actors' balances`
   (HNDb is a plain ERC20; only the owner mints to actors). HOLDS.
3. `invariant_hndConservation` — owner/handler + bond + escrow + actors == the
   initial 1M ether mint (HND is never created or destroyed). HOLDS.

### Result: ALL 3 INVARIANTS HOLD
- Green at default runs=200/depth=120 (~2s) and at runs=1000/depth=300 (~24s,
  300k calls per invariant with ~2.5k swallowed reverts each — the reverts are
  expired-lock redeems and no-backing mints, i.e. the fuzzer keeps hammering
  the surfaces that revert). 9/9 smoke tests pass.
- The Polygon v2 path is internally consistent: `mint` pulls backing 1:1
  before `_mint`; `burn` burns HNDb then returns the backing to the owner;
  `redeem` (create-lock then deposit) moves exactly `balance_` from the bond
  to the escrow and burns `balance_` HNDb — supply and backing move in lockstep
  under every adversarial sequence. No protocol flaw surfaced.

### Design observations (documented via smoke tests, not invariant violations)
1. **v1 escrow path is broken against veCRV-semantics escrows.** With
   `escrow_is_v2 = false`, `redeem()` first does `hnd.transfer(beneficiary,
   balance_)` (backing leaves the bond) and then calls
   `escrow.deposit_for(beneficiary, balance_)`, which pulls `_value` from
   `msg.sender` (the bond) — the bond never approves the escrow in this path,
   and it no longer holds the HND anyway. `redeem()` **always reverts**.
   `test_v1_redeem_always_reverts` pins this: even with a pre-existing
   long-lived lock, redeem reverts atomically and the user's HNDb + the bond's
   backing are untouched. Only relevant if a deployment sets `escrow_is_v2 =
   false`; the Polygon deployment uses v2 (and Polygon's v2 path approves the
   escrow; Moonriver's v2 path has no approve — see note below).
2. **`burn` is an exit to the owner, not the user.** Burning HNDb returns the
   backing to the owner (HundredBond.sol:49-52). A user who exits via burn
   gets nothing; only `redeem` (locking HND into their escrow) returns value.
   Combined with (3) below, a user whose lock expires has no profitable exit.
3. **An expired escrow lock can never be re-locked through the bond.** The v2
   `redeem` creates a lock only when `locked_.end == 0`; once a lock exists
   and its `end` has passed, the `else` branch requires
   `locked_.end >= now + bondUnlockDuration`, which can never hold again (no
   extend call). The user's only option is `burn`, which gives the backing to
   the owner — a UX/design fragility (in the real system the user can extend
   the lock directly in the voting escrow, but the bond provides no path).
4. **Moonriver variant**: identical except the v2 path omits `hnd.approve`
   (Moonriver.sol:68/71-72). Against an escrow that pulls from `msg.sender`
   this would also always revert; the production escrow there must pull from
   `_addr` or hold a standing allowance. The escrow source is not in the
   corpus, so this stays an observation.
5. `rescueHnd` after 51 weeks drains the entire backing (HundredBond.sol:87-90)
   — an emergency escape hatch by design; documented, not exposed to the fuzzer
   (the invariants only hold pre-rescue).

### Cross-reference with run3 static findings (hundred-finance, 0 findings)
- `run3/hundred-finance.json` contains **0 findings**, so there is nothing to
  cross-check. The three green invariants are independent confirmation that
  the bond's HND/HNDb accounting is sound; the observations above are
  structure-level (dead v1 path, exit asymmetry), not analyzer-visible.

## Status (session 8)
- basis-cash: Boardroom phantom-reward finding CONFIRMED (foundry + echidna).
- harvest-ousd: yield-delegation/negative-rebase finding CONFIRMED.
- credit-guild: full lending-loop harness GREEN (7/7 invariants; 9/9 smoke).
- compound-v2: CEther money-market harness GREEN (3/3 invariants; 9/9 smoke).
- hundred-bond: bond token-accounting harness GREEN (3/3 invariants at 200 and
  1000 runs; 9/9 smoke tests). No new finding; run3 hundred-finance is empty
  (0 findings). Two design observations (broken v1 escrow path; burn/exit
  asymmetry) documented.
- Total: **2 CONFIRMED static-invisible findings across 5 protocols**; three
  clean harnesses (credit-guild, compound-v2, hundred-bond).
- Next: 6th protocol (balancer-v2) or an echidna pass over the newer
  harnesses.

## Protocol 6: balancer-v2 (Vault) — sessions 9-10

Harness: `invariant_projects/balancer-v2/`
- Vendored the full Vault corpus (`Ethereum_1/0xba1222...566bf2c8`, 45 .sol
  files, all `pragma solidity ^0.7.0` + `pragma experimental ABIEncoderV2`)
  at `src/` with relative imports intact; solc 0.7.6 binary pinned in
  `foundry.toml` (evm istanbul, optimizer runs=200, `[invariant] runs=200
  depth=120 fail_on_revert=false call_override=false`).
- `test/MockERC20.sol` — minimal 18-dec ERC20 (balanceOf/transfer/
  transferFrom/approve + mint/burn helpers).
- `test/MockAuthorizer.sol` — permissive authorizer (`canPerform` always
  true), so the harness can exercise the whole Vault surface without
  governance restrictions.
- `test/MockPool.sol` — constant-product MINIMAL_SWAP_INFO pool (no swap or
  protocol fees; BPT minted/burned 1:1 with tokens in/out) so any accounting
  mismatch must come from the Vault, never from pool math. Registers itself
  in the Vault in its constructor (`registerPool` + `registerTokens`).
- `test/FlashLoanRecipient.sol` — three recipients: mode 0 fully repays
  (amount + fee), mode 1 never repays, mode 2 under-repays (half). Modes 1-2
  force the Vault's post-loan-balance guard (`BAL#515`) to revert.
- `test/BalancerHandler.sol` — 3 MockERC20s (A, B, C), two pools (A-B, B-C),
  8 actors (0x1111...0001..8) each seeded 100k of every token (distributed
  via `transfer`, so total supply stays exactly 1M ether per token), each
  approving the Vault for max. Actions: `swapGivenIn` / `swapGivenOut`
  (constant-product k), `joinPool` / `exitPool` (single-token), `flashLoan`
  (amount clamped to the Vault's balance, mode%3), `depositInternal` /
  `withdrawInternal` / `transferInternal` (UserBalanceOp ledger). Every action
  is wrapped in `vm.startPrank(actor)`/`vm.stopPrank()` — the single-shot
  `vm.prank` was found to be consumed by argument-evaluation calls (e.g.
  `pool.poolId()`) before the Vault call, leaking the test contract as
  `msg.sender` (`BAL#503 USER_DOESNT_ALLOW_RELAYER`); `startPrank` fixes it.
- `test/Invariants.t.sol` — 8 invariants; `test/Smoke.t.sol` — 8 round-trip
  tests.

Invariants (all exact, no tolerances except the k-smoke):
1. `token{A,B,C}_conservation` — handler + Vault + ProtocolFeesCollector + all
   8 actors == 1,000,000 ether per token (nothing created or destroyed).
2. `vaultLedger_token{A,B,C}` — `token.balanceOf(vault)` == sum of the pools'
   virtual cash for that token + sum of actors' internal balances. This is the
   strictest check: it ties the Vault's physical holdings to what the pool
   cash and internal-balance books say the Vault is owed. **All three VIOLATE
   under the teeth-check mutation** (see below), so they are sensitive to
   exactly the guarded-subtraction accounting paths the run3 flags point at.
3. `pool{0,1}_shares` — pool BPT `totalSupply == sum(actor balances)`.

Results:
- 8/8 smoke tests PASS (`test_join_mints_shares_and_moves_tokens`,
  `test_exit_roundtrip_returns_tokens`, `test_swap_given_in_breaks_even`
  (k non-decreasing), `test_flashLoan_repay_is_neutral`,
  `test_flashLoan_no_repay_reverts` (BAL#515), `test_flashLoan_underpay_reverts`
  (BAL#515), `test_internal_deposit_withdraw_roundtrip`,
  `test_internal_transfer_moves_internal_balance`).
- 8/8 invariants HOLD at runs=200/depth=120 and at
  `FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=300` — 300k calls per
  invariant. Per-contract action counts (high-run): joinPool ~37.5k,
  exitPool ~37.3k, swapGivenIn ~37.5k, swapGivenOut ~37.3k, flashLoan ~37.4k
  (~1.3k swallowed reverts = the mode-1/mode-2 non-repaying recipients hitting
  `BAL#515`), deposit/withdraw/transferInternal ~37-38k each, all others 0
  reverts.

Teeth-check (mutation, this session): commenting out the
`_increaseInternalBalance` line in `UserBalance.sol::_depositToInternalBalance`
(i.e. the Vault physically receives tokens but never credits the internal
book) made **all three `vaultLedger_*` invariants FAIL** within 50 low-run
passes while conservation stayed green (tokens still exist — the ledger is
what lies). Restored the line; suite green again. This proves the ledger
invariants can actually catch internal-balance accounting bugs in this code
base rather than only confirming trivially.

### Cross-reference with run3 static findings (balancer-v2, 19 MEDIUM findings)

All 19 run3 balancer-v2 findings are in the exact surfaces the harness was
built to stress (guarded arithmetic on flashLoan / pool balance / asset
transfer / swap index paths plus two governance ZeroAddress). Verdict: **19/19
DISMISSED**, independently corroborated by the green ledger/conservation suite.

| # | Detector | File:line | op | Verdict | Why |
|---|----------|-----------|-----|---------|-----|
| 1 | ZeroAddress | VaultAuthorization.sol:88 | `_authorizer = newAuthorizer` | DISMISSED | `authenticate`-gated governance setter; a bad authorizer is a self-DoS of governance, never a user-fund risk. Harness runs the whole surface under a permissive authorizer. |
| 2 | ZeroAddress | ProtocolFeesCollector.sol:57 | ctor `_vault` | DISMISSED | Construction-time; the Vault deploys the collector internally with its own address. Not attacker-controlled. |
| 3 | IntegerOverflow | PoolRegistry.sol:82 | `_nextPoolNonce += 1` | DISMISSED | Overflow needs 2^256 pool registrations. Nonce is unbounded by design; `registerPool` is permissionless and exercised (2 pools in the harness). |
| 4-9 | IntegerOverflow | PoolRegistry.sol:123/124/137/147×3 | `*`/`-`/shifts | DISMISSED | Pure bit-packing of nonce/specialization/address into `bytes32` with constant shifts/masks; inputs bounded by construction (20-byte address, 2-byte specialization, 10-byte nonce). Not fund arithmetic. |
| 10 | IntegerOverflow | UserBalance.sol:193 | `currentBalance - deducted` | DISMISSED | Guarded: `_require(currentBalance >= amount)` + `deducted = Math.min(currentBalance, amount)`. EXERCISED: 37k+ withdraw/transferInternal calls, 0 reverts; the teeth-mutation proved the ledger invariant detects internal-balance bugs. |
| 11 | IntegerOverflow | FlashLoans.sol:77 | `postLoanBalance - preLoanBalance` | DISMISSED | Guarded by `_require(postLoanBalance >= preLoanBalance)` (BAL#515). EXERCISED: ~37k flashLoan calls incl. ~1.3k reverts where no-repay/underpay recipients hit this guard and the whole loan reverted atomically; ledger+conservation stayed green. |
| 12-13 | IntegerOverflow | PoolBalances.sol:242/243 | `amountIn - fee` / `fee - amountIn` | DISMISSED | Ternary branch on `amountIn >= feeAmount`; neither side can underflow. EXERCISED: ~75k join/exit calls, 0 reverts. |
| 14 | IntegerOverflow | AssetTransfersHandler.sol:72 | `amount -= deductedBalance` | DISMISSED | `deductedBalance` is `Math.min(currentBalance, amount)` by construction. EXERCISED via manageUserBalance + swap pulls. |
| 15 | IntegerOverflow | AssetTransfersHandler.sol:131 | `msg.value - amountUsed` | DISMISSED | Guarded by `_require(msg.value >= amountUsed, INSUFFICIENT_ETH)`. ETH-only path; the harness is pure-ERC20 by design. |
| 16-17 | IntegerOverflow | Swaps.sol:411/412 | `indexIn -= 1` / `indexOut -= 1` | DISMISSED | EnumerableMap indices are stored +1 and the token is confirmed registered above (else `TOKEN_NOT_REGISTERED` reverts), so index >= 1 always. EXERCISED: ~75k swap calls, 0 reverts, ledger+conservation green. |
| 18-19 | IntegerOverflow | TemporarilyPausable.sol:52/55 | `block.timestamp + duration` | DISMISSED | Durations bounded by `_require(<= _MAX_PAUSE_WINDOW_DURATION)` (2y); `uint256` timestamp overflow unreachable; constructor-time only. |

The high-run fuzzer reached every one of these guarded paths
(flashLoan reverts = mode-1/mode-2 recipients, swaps/joins/exits/internal
with 0 reverts) with all three exactness invariants holding — independent
corroboration that the `-`/`-=`/`+` guards flagged by run3 are sound.

## Status (session 10)
- basis-cash: Boardroom phantom-reward finding CONFIRMED (foundry + echidna).
- harvest-ousd: yield-delegation/negative-rebase finding CONFIRMED.
- credit-guild: full lending-loop harness GREEN (7/7 invariants; 9/9 smoke).
- compound-v2: CEther money-market harness GREEN (3/3 invariants; 9/9 smoke).
- hundred-bond: bond token-accounting harness GREEN (3/3 invariants; 9/9 smoke).
- balancer-v2: Vault ledger harness GREEN (8/8 invariants at 200 and 1000
  runs; 8/8 smoke tests). No new finding; all **19 run3 balancer-v2 findings
  DISMISSED** (guarded-subtraction paths exercised green, ZeroAddress are
  governance/constructor). Teeth-check proved the ledger invariants catch
  internal-balance accounting bugs.
- Total: **2 CONFIRMED static-invisible findings across 6 protocols**; four
  clean harnesses (credit-guild, compound-v2, hundred-bond, balancer-v2).
- Next: 7th protocol (e.g. lido or ionic-protocol) or an echidna pass over
  the newer harnesses.

## Protocol 7: ionic-protocol (Ionic lending markets) — sessions 11-12

Harness: `invariant_projects/ionic-protocol/`
- Vendored the ionic core verbatim from the run1 full-code snapshot into
  `src/compound/`, `src/ionic/`, `src/utils/`, `src/oracles/`, `src/adrastia/`,
  `src/adrastia-periphery/rates/`; OZ deps vendored into `lib/
  openzeppelin-contracts-upgradeable/` and `lib/openzeppelin-contracts/`.
  Build pinned to solc 0.8.10, evm shanghai, optimizer runs 200,
  bytecode_hash none.
- Three stubs at literal import paths (`src/PoolLens.sol`,
  `src/IonicUniV3Liquidator.sol`, `src/ionic/AuthoritiesRegistry.sol`) keep
  `CToken.sol` / `CTokenInterfaces.sol` unmodified. Permissioning is
  neutralized in the stubs: `PoolLens.getHealthFactor = 0` +
  `IonicUniV3Liquidator.healthFactorThreshold = 0` makes every liquidation
  take the permissionless branch, and `MockFeeDistributor.canCall` returns
  true so `CToken.isAuthorized` never blocks.
- `test/SimpleComptroller.sol` — no oracle; pins both asset prices at 1e18
  implicitly and implements faithful seize math:
  `seizeTokens = repay * (1.08e18 incentive + 2.8e16 protocolSeizeShare +
  10e16 feeSeizeShare) / collateral.exchangeRateCurrent()`, i.e. a constant
  `TOTAL_SEIZE_PENALTY = 1.208e18`.
- `test/SimpleInterestRateModel.sol` — `borrowRatePerBlock = 3e12`
  (< `borrowRateMaxMantissa = 5e12` in CTokenInterfaces) so `accrueInterest`
  never reverts; supply rate 0.
- `test/MockFeeDistributor.sol` — IFeeDistributor implementer acting as the
  `ionicAdmin` (the `CErc20Delegator` constructor requires
  `msg.sender == ionicAdmin_`); its `deployMarket` is `public` only because
  `deployCErc20` (the interface fn) must call it internally. `canCall` → true.
- `test/IonicHandler.sol` — 2 markets (cUSDC 6dp / cWETH 18dp), 4 actors
  (0x1111...0001..0004), funding `[1_000_000e6, 10_000e18]`. Delegator setup:
  `new CErc20Delegate()` + `new CTokenFirstExtension()` →
  `MockFeeDistributor(cErc20Delegate, cTokenFirstExtension)` →
  `deployMarket(...)` → `_setImplementationSafe(cErc20Delegate, "")` →
  `_setAddressesProvider(ap)` → `setMarket(m, 0.8e18)`. Handler is the
  `AddressesProvider` owner, so the admin-setter actions
  (`adminSetAddress`, `adminSetFlywheelRewards`, `adminSetPlugin`,
  `adminSetRedemptionStrategy`, `adminSetFundingStrategy`,
  `adminSetBalancerPool`, `adminSetPendingOwner`, `adminTransferOwnership`)
  work. Every action calls `_tick()` = `VM.roll(block.number + 1)` so
  `accrueInterest` sees a positive block delta; `warpBlocks(b)` rolls
  `+ (b % 500) + 1`.
- `test/Actor.sol` — actor performs mint/redeem/borrow/repay/repayBehalf/
  liquidate/transfer/approveUnderlying via low-level calls with itself as
  `msg.sender` (no pranks, no `.value()` cheatcodes — value flows are atomic
  EVM transfers, per the compound-v2 lesson). Liquidation bounding:
  `maxRepay = collateral.balanceOf(borrower) * exchangeRate / 1.208e18` so
  `seizeTokens` never exceed the borrower's collateral (otherwise
  `liquidateBorrowFresh` reverts).
- `test/Invariants.t.sol` — `IonicInvariants` (StdInvariant getter ABI,
  `targetContracts` = handler, 4 targeted senders) with three invariants;
  `test/Smoke.t.sol` — 12 deterministic tests.

Invariants (all exact except the rounding-tolerant borrow ledger):
1. `invariant_ctokenConservation` — per market, `sum(actor cToken balanceOf)
   == cToken.totalSupply()` (cTokens are only minted to actors / burned from
   them; the market holds none). HOLDS.
2. `invariant_underlyingConservation` — per market, `handler + actors +
   market underlying balance == totalUnderlyingMinted[i]` (nothing created or
   destroyed; supply is capped by the funding amounts). HOLDS.
3. `invariant_borrowLedger` — `sum(actor borrowBalanceCurrent)` within
   `ROUNDING_TOLERANCE = 1e9` of `totalBorrowsCurrent` (per-market accrual
   rounding across the two 6dp/18dp books). HOLDS.

Results:
- 12/12 smoke tests PASS: 4 end-to-end market flows
  (`test_liquidate_endToEnd`, `test_accrualConservation` with
  `warpBlocks(1000)`, `test_transferConvervation`, `test_repayBehalf`) plus 8
  zero-address acceptance tests (below).
- 3/3 invariants HOLD at runs=200/depth=120 (24k calls per invariant, 0
  reverts, `actorLiquidate` called 1462× with 0 reverts) and at
  `FOUNDRY_INVARIANT_RUNS=500 FOUNDRY_INVARIANT_DEPTH=300` (150k calls per
  invariant, 0 reverts, ~108s). The borrow-ledger tolerance only absorbs the
  rate-model accrual rounding; the two conservation checks are exact.

### Cross-reference with run3 static findings (ionic-protocol, 18 MEDIUM findings)

All 18 run3 ionic findings are **CONFIRMED** (16 ZeroAddress + 2
StorageCollision upgrade-hazard). The 16 ZeroAddress findings are 8 unique
setters duplicated across the Optimism and Base deployments; each is pinned
by a dedicated smoke test that asserts the setter must NOT revert on
`address(0)`:

| # | Function | File:line | Verdict | Why |
|---|----------|-----------|---------|-----|
| 1 | `setFlywheelRewards(flywheelRewardsModule)` | AddressesProvider.sol:65 | CONFIRMED | No zero check; `test_setFlywheelRewards_zeroAccepted` proves `address(0)` is stored without revert. |
| 2 | `setPlugin(plugin)` | AddressesProvider.sol:79 | CONFIRMED | No zero check; `test_setPlugin_zeroAccepted`. |
| 3 | `setRedemptionStrategy(strategy, outputToken)` | AddressesProvider.sol:93 | CONFIRMED | No zero check; `test_setRedemptionStrategy_zeroAccepted`. |
| 4 | `setFundingStrategy(strategy, inputToken)` | AddressesProvider.sol:112 | CONFIRMED | No zero check; `test_setFundingStrategy_zeroAccepted`. |
| 5 | `setAddress(newAddress)` | AddressesProvider.sol:150 | CONFIRMED | No zero check; `test_setAddress_zeroAccepted`. |
| 6 | `setBalancerPoolForTokens(pool)` | AddressesProvider.sol:170 | CONFIRMED | No zero check; `test_setBalancerPool_zeroAccepted`. |
| 7 | `_setPendingOwner(newPendingOwner)` | SafeOwnableUpgradeable.sol:51 | CONFIRMED | No zero check (only `onlyOwner`); `test_setPendingOwner_zeroAccepted`. |
| 8 | `transferOwnership(newOwner)` | SafeOwnableUpgradeable.sol:89 | CONFIRMED | No zero check (only `onlyOwner`); `test_transferOwnership_zeroAccepted`. |

All eight are `onlyOwner`-gated admin configuration setters, so the impact is
misconfiguration / permanently bricked-references (and, for the pending-owner
pair, an ownership transfer to `address(0)` leaving the contract effectively
ownerless until `_acceptOwner` is gated against `address(0)`) — MEDIUM, not
HIGH: the address(0) can only be written by the owner themselves.

- StorageCollision ×2 (AddressesProvider.sol:12, one per chain): **CONFIRMED
  as a documented upgrade hazard, not an active collision.** `forge inspect
  storage-layout` places `pendingOwner` at slot 101 — after
  ContextUpgradeable `__gap[50]` (slots 1-50) and OwnableUpgradeable
  `__gap[49]` (slots 52-100) — so the current layout does not overlap any OZ
  variable. But `SafeOwnableUpgradeable`'s own NatSpec states the contract
  class's intent: "Existing OwnableUpgradeable contracts cannot be upgraded
  due to the extra storage variable that will shift the other." Inserting
  `pendingOwner` before `_addresses` moves every AddressesProvider field +1
  slot (in a plain-Ownable layout `_addresses` sits at slot 101); an in-place
  proxy upgrade from an OwnableUpgradeable-era implementation would read
  `pendingOwner`/`_addresses`/`plugins`/... from shifted locations and corrupt
  stored state. Latent; benign for a from-genesis deployment, which is what
  the invariants exercise.

## Protocol 8: rocket-pool (rETH token accounting) — sessions 13-14

Harness: `invariant_projects/rocket-pool/`
- Vendored `RocketTokenRETH.sol` + `RocketBase.sol` verbatim from the run1
  full-code snapshot into `src/contract/contract/token/` and
  `src/contract/contract/`, solc 0.7.6 (the real rETH deployment compiler),
  matching the compound-v2 playbook. No source edits to the token.
- `test/MockStorage.sol` — RocketStorage stand-in exposing the uint/address
  maps the token reads (`getUint`, `setUserDepositBlock`, ...);
  `test/MockDepositPool.sol` — a pool where all ETH is excess;
  `deposit()` sets `user.deposit.block = block.number`, `mintReth` /
  `depositExcessReth` call the token with the pool as `msg.sender` (mirroring
  the real mint/excess gating); `test/MockNetworkBalances.sol` — oracle that
  only ever receives honest reports; `test/MockDAOProtocolSettingsNetwork.sol`
  — pins `network.reth.deposit.delay = 10`, `network.reth.collateral.rate =
  0.9 ether`.
- `test/Actor.sol` — 8 real on-chain users, each holding 100 ETH + 250 rETH;
  deposit/depositAndMint/burn/transfer execute with the actor as `msg.sender`
  (no prank-based balance redirection — the compound-v2 lesson).
- `test/RocketHandler.sol` — entry points deposit/depositAndMint/burn/
  transfer/stake/advanceBlocks/depositExcess/depositExcessCollateral. Every
  routed action first calls `_tick()` = `VM.roll(block.number + DEPOSIT_DELAY
  + 1)` so the `_beforeTokenTransfer` deposit-delay guard always passes (see
  the foundry-bug note below). `_bound` preserves in-range values and maps
  out-of-range fuzz inputs via modulo; burns are capped at the actor's rETH
  balance so the only legitimate reverts left are liquidity-bound.
- `test/Invariants.t.sol` — `RocketInvariants` (raw StdInvariant ABI), target
  = handler, 8 targeted senders, `targetSelectors` = deposit + burn;
  `test/Smoke.t.sol` — 8 deterministic tests.

Invariants (all exact):
1. `invariant_ethConserved` — `sum(actor ETH) + handler + rETH + pool +
   validator == CONSERVATION_CONSTANT (2800 ether = 2000 seed + 8×100)`.
   HOLDS.
2. `invariant_rethSupplyConserved` — `sum(actor rETH) + handler rETH ==
   reth.totalSupply()`. HOLDS.
3. `invariant_collateralRateBounded` — `getCollateralRate() <= 1 ether`.
   HOLDS.
4. `invariant_rethFullyBacked` — `getEthValue(totalSupply) <= realBacking()`.
   HOLDS.

Results:
- 8/8 smoke tests PASS, incl. the deposit-delay guard driven *directly*
  through the protocol (bypassing the handler `_tick()`), the liquidity
  revert, the oracle-inflation boundary, and mint-gating.
- 4/4 invariants HOLD at runs=200/depth=120 (24k calls per invariant, 0
  reverts) and at `FOUNDRY_INVARIANT_RUNS=500 FOUNDRY_INVARIANT_DEPTH=300`
  (150k calls per invariant, 0 reverts). The two conservation checks are
  exact.

### Foundry bug: the invariant fuzzer commits state for reverted calls (the real find)

The harness was initially red: `invariant_ethConserved` and
`invariant_collateralRateBounded` showed phantom conservation breaks where an
actor's balance silently dropped to 0 immediately after a *reverted* fuzz
call — e.g. actor a2 = 0 with `sum` −100e18 in the very next state after a
deposit-delay revert on actor a7; and the ethConserved counterexample ended
with `a7 = 0` despite its last `DebugDeltas` showing `a7 =
214231133446067935592`.

Root cause is executor-level, not contract-level:
- The invariant fuzzer **commits the state changeset for reverted calls too**
  (`foundry_invariant.rs:547`, `current_run.executor.commit(&mut call_result)`,
  sits *outside* the `!call_result.reverted` guard — `collect_data` at :557 is
  gated, the commit is not). Under reverts, the post-revert revm changeset is
  applied to the journaled state and a touched account can end up zeroed.
- Isolation: deposit-only and burn-only campaigns PASS (24k calls, 0 reverts
  each) on the same seed — the leak needs interleaved deposit+burn, i.e. the
  deposit-delay reverting path.
- The exact shrunk 8-call counterexample **conserves under plain EVM replay**
  (prank + try/catch, and as a DappTest) with `a7 = 214231133446067935592` —
  identical bytes, identical guard, no leak outside the fuzzer's `call_raw`.
- The leak never appears after a successful call; it appears only once a
  reverting `call_raw` fuzz call has been committed.

Harness resolution: the deposit-delay guard legitimately blocks same-block
deposit→transfer, and reverts are the trigger, so the handler advances the
chain past DEPOSIT_DELAY with `_tick()` — modeling the passage of time the
real protocol demands. This removes reverts from the fuzzed surface; the
failing seed now passes all 4 invariants with 0 reverts, and the guard is
still pinned by a smoke test that drives the protocol directly.

### Cross-reference with run3 static findings (rocket-pool, 3 MEDIUM findings)

| # | Detector | File:line | op | Verdict | Why |
|---|----------|-----------|-----|---------|-----|
| 1 | ZeroAddress | RocketBase.sol:105 | ctor `_rocketStorageAddress` | DISMISSED | Construction-time, single immutable storage reference assigned once at deploy; not attacker-controlled. Harness deploys it with a real MockStorage and runs every token path against it. |
| 2 | FrontRunning | RocketTokenRETH.sol:132 | `burn` | DISMISSED | Burn's ETH out is `getEthValue`, set by the protocol collateral rate — a deterministic, oracle-fed price with no order book/AMM leg to front-run; deposits are additionally gated by the deposit-delay guard. Exercised ~12k burn calls per invariant at 0 reverts. |
| 3 | MEV | RocketTokenRETH.sol:132 | `burn` | DISMISSED | Same pricing argument as FrontRunning: collateral-ratio pricing is not MEV-extractable. |

Verdict: **3/3 DISMISSED**, independently corroborated by the green
conservation/backing suite.

## Protocol 8 cross-check: Echidna on the rocket-pool harness (session 14)

Setup: echidna 2.3.3 (`~/.config/.foundry/bin/echidna`) + `crytic-compile`
0.4.2 in a dedicated venv (`/tmp/opencode/echidna_venv`), compiled through
crytic-compile's Foundry framework (`forge build`). solc 0.7.6 wired into
`solc-select` (`~/.solc-select/artifacts/solc-0.7.6`) matching the project's
`foundry.toml` `solc` pin. `VM.deal` cheatcode support verified empirically
with a probe before the campaign (the handler funds its 8 actors with `deal`
in the constructor).

Harness additions:
- `test/EchidnaRocketPool.sol` — composition wrapper over `RocketHandler`;
  forwards the 2 fuzz actions (deposit, burn) and exposes 4 `echidna_*` view
  properties (eth_conserved, reth_supply_conserved, collateral_rate_bounded,
  reth_fully_backed).
- `echidna.yaml` — `testMode: property`, `testLimit: 50000`, `seqLen: 100`,
  `filterBlacklist: false` with an explicit whitelist of the 2 action
  functions.

Results (two seeds):
- Seed A (default) and seed 12345: **all 4 properties passing** (~50k tests,
  100-deep sequences, ~50k calls, 7198 instr / 8 codehashes coverage).
  Independent confirmation of the foundry suite: the rETH conservation and
  backing invariants hold under an unrelated fuzzer, with the foundry
  invariant-fuzzer revert-journaling bug absent (echidna never commits
  reverted-call state).

Conclusion: two independent fuzzers (foundry 1.7.1 invariant mode and echidna
2.3.3) agree: the rocket-pool rETH token-accounting harness is GREEN.

## Protocol 9: morpho-blue (Morpho lending ledger) — sessions 15-16

Harness: `invariant_projects/morpho-blue/`
- Vendored `Morpho.sol` + interfaces + libraries verbatim from the run3
  full-code snapshot into `src/core/`, solc 0.8.19 (the real deployment
  compiler, pinned in `foundry.toml`, `evm_version = "paris"`,
  `via_ir = true`). No source edits to the core.
- `src/mocks/MockERC20.sol` (standard USDC 6dp + WETH 18dp), `MockOracle.sol`
  (returns `price_`, settable — used for liquidation shocks),
  `MockIrm.sol` (constant 5% APR per-second WAD).
- `test/MorphoHandler.sol` — two cross-token markets: A = loan USDC / coll
  WETH (oracle 2000 USDC/WETH, LLTV 86%, fee 10%) and B = loan WETH / coll
  USDC (oracle 1/2000, LLTV 80%, fee 0%). 8 actors prefunded 1M USDC + 1000
  WETH, `targetSenders` = actors, prank-based sender redirection (all value is
  ERC20, no ETH — the balancer-v2 playbook). Every Morpho call routes through
  a low-level call whose revert is swallowed, so handler functions never
  revert (the rocket-pool lesson: foundry's invariant fuzzer commits state for
  reverted calls). Fuzz actions: supply, supplyCollateral, borrow, withdraw,
  withdrawCollateral, repay, liquidate (oracle shocked to a random 0.001%–100%
  of the honest price, then restored — all invariants are price-independent),
  accrue, warp, setFee, setFeeRecipient, setOwner (governance ones owner-gated
  while owner == OWNER).
- `test/Invariants.t.sol` — `MorphoInvariants` (raw StdInvariant ABI), target
  = handler, 8 targeted senders, 12 selectors; `test/Smoke.t.sol` — 8
  deterministic tests; `test/Debug.t.sol` — shrunk-counterexample replay.

Invariants (10, all exact ledger identities):
1. `invariant_supplySharesConserved_m0/m1` — sum(actors + feeRecipient +
   address(0)) supply shares == totalSupplyShares. HOLDS.
2. `invariant_borrowSharesConserved_m0/m1` — sum(actors) borrow shares ==
   totalBorrowShares. HOLDS.
3. `invariant_usdc/wethBalanceConserved` — morpho's token balance is never
   below the market idle pool plus the counterpart market's collateral for
   that token (USDC = m0 idle + m1 collateral, WETH = m1 idle + m0
   collateral). HOLDS.
4. `invariant_usdc/wethLedgerResidual` — every token-moving action moves the
   physical balance in lockstep with the book, or exceeds it by exactly the
   protocol's 1-wei repay rounding. HOLDS.
5. `invariant_marketSolvent_m0/m1` — totalSupplyAssets >= totalBorrowAssets.
   HOLDS.

Results:
- 8/8 smoke tests PASS (roundtrips; liquidate unhealthy position; bad-debt
  write-off keeps solvency; fee accrual credits the fee recipient;
  insufficient-liquidity revert; zero-address + owner guards incl. the
  documented `setOwner(0)` one-way door; same-block roundtrip creates no free
  value).
- 10/10 invariants HOLD at runs=200/depth=120 (24k calls per invariant, 0
  reverts) and at `FOUNDRY_INVARIANT_RUNS=500 FOUNDRY_INVARIANT_DEPTH=300`
  (150k calls per invariant, 0 reverts).

### The harness surfaced a real protocol-rounding behavior: 1-wei repay dust

The absolute balance-sheet identity (`balanceOf(morpho) == idle + collateral`)
is NOT exact: it can diverge by more than 1 wei. Root-caused with a shrunk
5-call counterexample (`supplyCollateral → supply → borrow → repay → repay`):
Morpho's virtual-share accounting (`SharesMathLib`: VIRTUAL_SHARES = 1e6,
VIRTUAL_ASSETS = 1) lets a repayment of the last borrow share compute
`assets = toAssetsUp(shares)` one wei above `totalBorrowAssets`, so `repay`
pulls `totalBorrowAssets + 1` into the pool while zeroing the borrow book
(Morpho.sol:290: "`assets` may be greater than `totalBorrowAssets` by 1").
Each full-book-share repayment of a micro-borrow cycle adds another +1 wei of
dust (observed delta 2 across two cycles), so the cumulative gap is unbounded
over fuzzing and no fixed tolerance is sound.

Resolution: the ledger invariant was reformulated as the exact per-action
bound — each single action may diverge physical vs book by at most +1 wei
(repay/liquidate rounding), never less than 0 (no value leak). The handler
records `lastUsdcResidual`/`lastWethResidual` per routed call and the residual
invariants assert them in {0, 1}. This is both the strongest no-value-creation
check (a mint-without-transfer, borrow-without-transfer, or flash-loan theft
pushes the residual out of {0, 1}) and, coincidentally, exactly the
`balanceOf`-delta discipline the run3 ValueFlow detector recommends.

### Cross-reference with run3 static findings (morpho-blue, 7 findings)

| # | Detector | File:line | op | Verdict | Why |
|---|----------|-----------|-----|---------|-----|
| 1 | ZeroAddress | Morpho.sol:95 | `setOwner` | DISMISSED | By design — the interface documents "the owner can be set to the zero address" (one-way governance renouncement, no two-step transfer). Smoke-pinned: `setOwner(0)` permanently locks governance with "not owner"; no funds at risk. |
| 2 | ZeroAddress | Morpho.sol:139 | `setFeeRecipient` | DISMISSED | By design — same governance-renouncement pattern; fee shares simply accrue to address(0). Harness covers it: fee-share conservation sums address(0) as a tracked position, so a zero fee recipient cannot orphan book value. |
| 3 | ValueFlow | Morpho.sol:183 | `supply` | DISMISSED | The credit equals the atomically-transferred `assets` for standard (non-fee-on-transfer) ERC20s, which the interface explicitly requires ("tokens with fees on transfer are not supported"). The residual invariant IS the recommended balanceOf-delta check and stays {0,1} across 150k calls — a FoT divergence would trip it. |
| 4 | ValueFlow | Morpho.sol:283 | `repay` | DISMISSED | Same documented token assumption as #3; `safeTransferFrom(assets)` matches the borrow-book decrement exactly. |
| 5 | AccessControl | Morpho.sol:347 | `liquidate` | DISMISSED | Permissionless liquidation is the intended design (incentive-bounded; requires `!_isHealthy` against the governance-set oracle). Harness drives liquidate from arbitrary actors under oracle shocks; all invariants green. |
| 6 | AccessControl | Morpho.sol:446 | `setAuthorizationWithSig` | DISMISSED | The access control IS the EIP-712 signature check (`require(signatory != address(0) && authorization.authorizer == signatory)`); the detector missed the `ecrecover` pattern. Nonce/deadline guarded. |
| 7 | Reentrancy | Morpho.sol:489 | `_accrueInterest` | DISMISSED | The "external call" is `IIrm.borrowRate` to an owner-whitelisted IRM (only `enableIrm`, itself onlyOwner); state mutation after a read-only trusted-dependency call is not exploitable. In all token-moving functions Morpho follows checks-effects-interactions strictly (state written before transfers/callbacks), exercised by the whole harness. |

Verdict: **7/7 DISMISSED**, independently corroborated by the green
ledger/residual suite (the residual invariants are the exact
`balanceOf`-delta discipline the ValueFlow findings call for).

### Protocol 9 cross-check: Echidna on the morpho-blue harness

`test/EchidnaMorphoBlue.sol` (composition wrapper, the rocket-pool pattern) +
`echidna.yaml` (testMode property, testLimit 50000, seqLen 100, whitelist of
the 12 forwarded fuzz actions). echidna 2.3.3 with crytic-compile 0.4.2
(venv) and solc 0.8.19 via solc-select (added to `~/.solc-select/artifacts/`,
global = 0.8.19). Result (fresh random seed 5539492503410371496):

```
echidna_weth_ledger_residual: passing
echidna_usdc_balance_conserved: passing
echidna_market_solvent_m0: passing
echidna_supply_shares_conserved_m1: passing
echidna_usdc_ledger_residual: passing
echidna_borrow_shares_conserved_m1: passing
echidna_borrow_shares_conserved_m0: passing
echidna_weth_balance_conserved: passing
echidna_supply_shares_conserved_m0: passing
echidna_market_solvent_m1: passing
Total calls: 50234, 0 failures, cov 14843 instr, corpus 13
```

**10/10 properties passing.** The residual properties hold under echidna's
arbitrary byte-level calldata fuzzing too, confirming the {0,1} per-action
bound is a property of Morpho's arithmetic, not of the foundry fuzzer's call
distribution. Both independent fuzzing engines agree with the foundry
150k-call runs.

## Status (session 16)
- basis-cash: Boardroom phantom-reward finding CONFIRMED (foundry + echidna).
- harvest-ousd: yield-delegation/negative-rebase finding CONFIRMED.
- credit-guild: full lending-loop harness GREEN (7/7 invariants; 9/9 smoke).
- compound-v2: CEther money-market harness GREEN (3/3 invariants; 9/9 smoke).
- hundred-bond: bond token-accounting harness GREEN (3/3 invariants; 9/9 smoke).
- balancer-v2: Vault ledger harness GREEN (8/8 invariants at 200 and 1000
  runs; 8/8 smoke tests); 19/19 run3 findings DISMISSED.
- ionic-protocol: lending-market harness GREEN (3/3 invariants at 200 and 500
  runs, 150k calls, 0 reverts; 12/12 smoke tests). All **18 run3 ionic
  findings CONFIRMED** — 16 ZeroAddress (8 owner setters × 2 chains, each
  smoke-pinned) and 2 StorageCollision (documented upgrade hazard; no active
  slot overlap in the current layout).
- rocket-pool: rETH token-accounting harness GREEN (4/4 invariants at 200 and
  500 runs, 150k calls, 0 reverts; 8/8 smoke tests; echidna 2.3.3 cross-check
  on 2 seeds, all 4 properties passing). Root-caused a second foundry
  invariant-fuzzer bug — it **commits state changesets for reverted calls**
  (foundry_invariant.rs:547), zeroing actor balances after reverts — and
  resolved it in-harness by modeling the deposit-delay block advance
  (`_tick()`). All **3 run3 rocket-pool findings DISMISSED** (constructor
  ZeroAddress; burn front-run/MEV against deterministic collateral-ratio
  pricing).
- morpho-blue: Morpho lending-ledger harness GREEN (10/10 invariants at 200
  and 500 runs, 150k calls, 0 reverts; 8/8 smoke tests). Surfaced and
  root-caused Morpho's 1-wei repay dust (virtual-share rounding lets a
  full-book-share repayment overpay 1 wei; cumulative gap unbounded, so the
  ledger invariant is formulated per-action as residual in {0,1}). All **7
  run3 morpho-blue findings DISMISSED** (zero-address owner/recipient setters
  and permissionless liquidate by design; ValueFlow supply/repay under the
  documented non-FoT token assumption — the residual invariant is the exact
  balanceOf-delta discipline the detector calls for; ecrecover auth and
  trusted-IRM accrue FPs).
- Total: **2 CONFIRMED static-invisible findings** (basis-cash, harvest-ousd),
  **18/18 run3 ionic findings verified**, and **7/7 + 3/3 + 19/19 run3
  morpho-blue/rocket-pool/balancer-v2 findings DISMISSED**; seven clean
  harnesses (credit-guild, compound-v2, hundred-bond, balancer-v2,
  ionic-protocol, rocket-pool, morpho-blue), of which rocket-pool and
  morpho-blue additionally pass echidna cross-checks.
## Protocol 10: compound-v3 (Comet lending market) — sessions 18-19

Harness: `invariant_projects/compound-v3/`
- Vendored verbatim from the run3 full-code snapshot into `src/core/`:
  `CometWithExtendedAssetList.sol` (+ CometCore, CometConfiguration, CometMath,
  CometStorage, CometMainInterface, IAssetList*, IERC20NonStandard, IPriceFeed)
  — no source edits. solc 0.8.15 (the deployment compiler, pinned in
  `foundry.toml`, `evm_version = "paris"`, `via_ir = true`).
- Constructor config: baseToken USDC 6dp at a $1 feed; collateral WETH 18dp at
  $2000 (BCF 0.8 / LCF 0.9 / LiqF 0.92) and WBTC 8dp at $30000 (BCF 0.75 /
  LCF 0.85 / LiqF 0.9); storeFrontPriceFactor 0.5; supply kink 0.8;
  `borrowPerYearInterestRateBase = 0.04e18` — chosen so
  `util * borrowRate >= supplyRate` over the whole utilization range, making
  reserve growth structurally non-negative. 8 actors prefunded 1M USDC / 1000
  WETH / 100 WBTC.
- `test/CometHandler.sol` — prank-based sender redirection (all value ERC20,
  the balancer-v2 playbook); every Comet call routes through a low-level call
  whose revert is swallowed so handler functions never revert (the rocket-pool
  fuzzer-commit lesson; `fail_on_revert = false` in foundry.toml). Fuzz
  actions: `supply`, `withdraw`, `transfer`, `absorb` (oracle shocked to a
  random fraction of the honest price first, then restored — the actual
  oracle-shock surface), `buyCollateral`, `pause`, `warp`. `_tick()` is not
  called between absorbs, so interest accrues on the supply/withdraw/transfer
  ticks and absorb reserves-deltas are exact against the debt bound.
- `test/Invariants.t.sol` — raw StdInvariant ABI, `targetContracts` = handler,
  `targetSenders` = 8 actors, 7 selectors; `test/Smoke.t.sol` — 7
  deterministic tests.

Invariants (7, all exact ledger identities):
1. `invariant_baseBookConserved` — sum(actor positive principal) ==
   totalSupplyBase and sum(actor |negative principal|) == totalBorrowBase
   (Comet stores principals directly, no share conversion, so this holds
   exactly and catches any mint/borrow/double-spend corruption). HOLDS.
2-3. `invariant_collateralBookWeth/Wbtc` — every WETH/WBTC collateral unit
   lives in a tracked actor account (sum == totalsCollateral.totalSupplyAsset,
   read via the handler's `tick` tracking). HOLDS.
4. `invariant_baseNoLeak` — reserves (= balance − presentSupply +
   presentBorrow) + absorbedBadDebt >= 0. HOLDS.
5. `invariant_lastResidual` — every non-absorb action leaves reserves
   non-decreasing up to one base unit of rounding dust. HOLDS.
6. `invariant_absorbAccounting` — absorption never writes off more debt than
   the account owed (delta >= −(debtBefore + DUST)). HOLDS.
7. `invariant_marketSolvent` — balance + totalBorrow + absorbedBadDebt >=
   totalSupply. HOLDS.

Results:
- 7/7 smoke tests PASS (base/collateral supply-withdraw and
  borrow-repay-collateral roundtrips; base/collateral transfer; absorb writes
  off bad debt exactly; interest accrual over a 30-day warp with reserves
  non-decreasing and the market solvent; governance/guard reverts;
  roundtrip creates no free value).
- 7/7 invariants HOLD at runs=200/depth=120 (24k calls per invariant, 0
  reverts) and at 500/300 (150k calls per invariant, 0 reverts) on 4 seeds,
  including the previously-failing
  `0xbc9dc4362559ef0da3794ba32409aede0a8c5051427a2aa09aca7ca33b96bc42` and
  seeds 1, 42, 1337.

### Three false invariants root-caused and reformulated (real protocol behavior)

1. **`totalSupply() >= totalBorrow()` is NOT Comet's solvency condition.**
   Both are present-value views of the internal `totalSupplyBase` /
   `totalBorrowBase`; in the profitable case the borrow index grows faster than
   the supply index, so the naive inequality fails while the market is
   perfectly healthy. Replaced with the physical + borrow + absorbedBadDebt >=
   supply form (7).
2. **Absorb can legitimately GROW reserves.** Seized collateral at the
   liquidation factor can over-cover a liquidatable debt (the liquidatable band
   between LiqF 0.9 and the ~1.02 liquidateCollateralFactor); the surplus
   becomes a supply position and reserves grow — positive absorb deltas are
   legal and not enforced. And `absorb`'s internal write-off can exceed the
   externally measured `borrowBalanceOf` by exactly 1 base unit (index/PV
   rounding), so the bound is `delta >= -(debtBefore + DUST)` with DUST = 1.
3. **Non-absorb actions can move exactly 1 base unit out of reserves** via the
   `principalValue`/`presentValue` floor round-trip (≤ 1e-6 USDC), the Comet
   analog of Morpho's 1-wei repay dust — so the residual bound is `delta >=
   -DUST`, not `delta >= 0`.

### Cross-reference with run3 static findings (compound-v3, 13 findings)

| # | Detector | File:line | op | Verdict | Why |
|---|----------|-----------|-----|---------|-----|
| 1-3,6,9 | OracleManipulation | CometCore:345,386,429 / CometWithExtendedAssetList:1065,1151 | `getPrice` (latestRoundData without staleness/round validation) | DISMISSED | The handler's MockPriceFeed always returns `updatedAt=1`/`answeredInRound=1`; the price read has no state effects. The value-moving consumption of that read is the absorb path, which the harness shocks across the full price range and which is pinned by invariant_absorbAccounting / invariant_baseNoLeak / invariant_marketSolvent. |
| 7-8 | OracleTaint | CometWithExtendedAssetList:1065,1076 | `getPrice` feeds `absorb`/`buyCollateral` (value-moving) | DISMISSED | Same rationale: absorb/buyCollateral ARE the harness's oracle-shock surface; all 7 invariants hold across 150k calls per invariant with prices shocked to a random 0.001%–100% of honest. |
| 0 | Timestamp | Comet:246 | `block.timestamp` gating in `accrueInternal` | DISMISSED | Interest accrual is time-based by design (`lastAccrualTime`); the harness warps by up to 2 years and every accrual identity (book, no-leak, solvency) holds. |
| 4-5 | ZeroAddress | CometCore:604,634 | `updateAssetsIn(assetInfo)` / `updateBasePrincipal(basic)` | DISMISSED | Internal functions reachable only from governed/guarded external paths (`updateAsset` requires the admin; `updateBasePrincipal` is called by borrow/withdraw/transfer internals that already validate the account exists and is non-zero). |
| 10-11 | SignatureReplay | Extension:34 | signed allowance (`allowBySig`) | DISMISSED | Harness exercises only the direct `allow` path via the MockExtensionDelegate, so the signed flow is out of scope; the real `allowBySig` is EIP-712 `ecrecover`-guarded with a nonce + expiry. |
| 12 | Unassigned | Extension storage | `isAllowed` never assigned in the main contract | DISMISSED | Extension storage is written only via delegatecall to the extension delegate (the `allow`/`allowBySig` path); the main contract's storage layout intentionally carries it unassigned. |

Verdict: **13/13 DISMISSED.** The oracle findings are the static-only, un-
shockable subset of what the harness's absorb/buyCollateral fuzz actions
already stress with prices driven to extremes; the remaining findings are
governed/internal-path FPs and the delegatecall extension-storage artifact.

## Status (session 19)
- basis-cash: Boardroom phantom-reward finding CONFIRMED (foundry + echidna).
- harvest-ousd: yield-delegation/negative-rebase finding CONFIRMED.
- credit-guild: full lending-loop harness GREEN (7/7 invariants; 9/9 smoke).
- compound-v2: CEther money-market harness GREEN (3/3 invariants; 9/9 smoke).
- hundred-bond: bond token-accounting harness GREEN (3/3 invariants; 9/9 smoke).
- balancer-v2: Vault ledger harness GREEN (8/8 invariants at 200 and 1000
  runs; 8/8 smoke tests); 19/19 run3 findings DISMISSED.
- ionic-protocol: lending-market harness GREEN (3/3 invariants at 200 and 500
  runs, 150k calls, 0 reverts; 12/12 smoke tests). All **18 run3 ionic
  findings CONFIRMED** — 16 ZeroAddress (8 owner setters × 2 chains, each
  smoke-pinned) and 2 StorageCollision (documented upgrade hazard; no active
  slot overlap in the current layout).
- rocket-pool: rETH token-accounting harness GREEN (4/4 invariants at 200 and
  500 runs, 150k calls, 0 reverts; 8/8 smoke tests; echidna 2.3.3 cross-check
  on 2 seeds, all 4 properties passing). Root-caused a foundry invariant-fuzzer
  bug — it **commits state changesets for reverted calls** (foundry_invariant.rs:547).
  All **3 run3 rocket-pool findings DISMISSED**.
- morpho-blue: Morpho lending-ledger harness GREEN (10/10 invariants at 200
  and 500 runs, 150k calls, 0 reverts; 8/8 smoke tests). Surfaced and
  root-caused Morpho's 1-wei repay dust; the ledger invariant is formulated
  per-action as residual in {0,1}. All **7 run3 morpho-blue findings
  DISMISSED**. Echidna 2.3.3 cross-check PASSED (10/10 properties).
- compound-v3: Comet lending-market harness GREEN (7/7 invariants at 200 and
  500 runs, 150k calls, 0 reverts on 4 seeds; 7/7 smoke tests). Root-caused
  and reformulated three naive invariants: `totalSupply() >= totalBorrow()`
  is not Comet's solvency condition, absorb can legitimately grow reserves
  (over-covered collateral), and non-absorb actions can move 1 base unit of
  principalValue floor-rounding dust. All **13 run3 compound-v3 findings
  DISMISSED** (9 OracleManipulation/OracleTaint HIGH + 1 Timestamp LOW are the
  oracle-read surface the harness shocks through `absorb`; 2 ZeroAddress
  internal-path FPs; 2 SignatureReplay on the delegatecall extension's signed
  allow; 1 delegatecall-only extension storage artifact).
- Total: **2 CONFIRMED static-invisible findings across 10 protocols**
  (basis-cash, harvest-ousd); eight clean high-value harnesses (credit-guild,
  compound-v2, hundred-bond, balancer-v2, ionic-protocol, rocket-pool,
  morpho-blue, compound-v3), of which rocket-pool and morpho-blue additionally
  pass echidna cross-checks; 18/18 run3 ionic findings verified and **42/42
  run3 morpho-blue/rocket-pool/balancer-v2/compound-v3 findings DISMISSED**.

## Protocol 11: monolith-market (Lender/Vault lending market) — session 20

Harness: `invariant_projects/monolith-market/`
- Vendored verbatim from the run3 full-code snapshot into `src/`: `Lender.sol`,
  `Vault.sol`, `Factory.sol`, `Coin.sol`, `InterestModel.sol` + solmate deps
  (no source edits). solc 0.8.13 (the deployment compiler, pinned in
  `foundry.toml`, `evm_version = "paris"`, `via_ir = true`).
- Deployment: Factory operator is `0x2000` (constructor-set — a distinct
  account, NOT actors[0]); lender operator is actors[0], fee recipient
  actors[1]. The 1% factory fee is set BEFORE `factory.deploy` — the Lender
  caches `cachedGlobalFeeBps` only at construction and on a successful
  `accrueInterest`, so a post-deploy fee change would never reach the accrual.
  One collateral asset (MockCollateral WSTONE) at a settable MockChainlinkFeed
  ($1800, 8dp), `collateralFactor` 75%, `minDebt` 10 Coin, 30-day deadline.
- `test/MonolithHandler.sol` — 6 actors prefunded 1M collateral; prank-based
  sender redirection (all value ERC20); every Lender/Vault call routes through
  a low-level call whose revert is swallowed so handler functions never revert
  (the rocket-pool fuzzer-commit lesson; `fail_on_revert = false`). 19 fuzz
  actions: `adjustDeposit/adjustBorrow/adjustRepay/adjustWithdraw`,
  `combinedBorrow`, `optInRedemption/optOutRedemption`, `liquidate` (feed
  shocked to 0.1%–100% of honest price, restored), `redeem`, `attemptWriteOff`
  (bounded debtor/to indexes), `vaultDeposit/vaultMint/vaultWithdraw/
  vaultRedeem` (ERC4626), `shockPrice` (fresh honest / 50–150% / stale
  26h–3d), `warp` (0–365d), `operatorSetter` (fee/ratio/half-life setters),
  `pullLocalReserves`, `pullGlobalReserves`.
- `test/Invariants.t.sol` — raw StdInvariant ABI, `targetContracts` = handler,
  `targetSenders` = 6 actors, 19 selectors; `test/Smoke.t.sol` — 8
  deterministic tests.

Invariants (5, all exact ledger identities):
1. `invariant_coinLedger` — `coin.totalSupply() == totalFreeDebt +
   totalPaidDebt - accruedLocalReserves - accruedGlobalReserves`. Every
   borrow/repay/redeem/liquidate/write-off/interest-accrual/reserve-pull moves
   supply and the debt+reserve book by the same amount, so a double mint, a
   skipped burn or a share-book mismatch breaks it exactly. **VIOLATED
   (CONFIRMED finding).**
2. `invariant_paidSharesConserved` — `sum(paidDebtShares[actor]) ==
   totalPaidDebtShares` (the redemption index only rewrites free-debt shares).
   HOLDS.
3. `invariant_vaultSharesConserved` — the vault share book is exactly the 6
   actors plus the MIN_SHARES (1e16) dead shares at address(0) donated against
   the ERC4626 inflation attack. HOLDS.
4. `invariant_vaultCovered` — `vault.totalAssets() >= vault.totalSupply()`
   (shares always 1:1 covered; no share inflation). HOLDS.
5. `invariant_lenderHoldsNoCoin` — every Coin that reaches the lender (repay,
   redeem, liquidate) is burned in the same call. HOLDS.

Results:
- 8/8 smoke tests PASS (deposit/borrow/repay/withdraw round-trip, solvency +
  authorization guards, liquidation at a 5% price shock, redeem against free
  debt with lazy collateral debit, vault deposit/withdraw round-trip with
  MIN_SHARES dead-share accounting, interest accrual over a 30-day warp +
  global reserve pull, writeOff last-debtor pin).
- 4/5 invariants HOLD at runs=200/depth=120 (24k calls per invariant, 0
  reverts) and at 500/300 (150k calls per invariant, 0 reverts) on seeds 42
  and 1337.
- `invariant_coinLedger` FAILS deterministically. Stable 2-call shrunk
  counterexample (identical across runs, seeds, and the 500/300 deep run):
  1. `combinedBorrow(3647824450842923331174363683827,
     14928331485464224384976708264443215047998206326689562727012306)` from
     actor 0x1001 (deposit + borrow).
  2. `attemptWriteOff(27560079151)` from actor 0x1000 — `_tick` advances ~30h
     so the feed is stale (25h threshold, in the 49h unwind window where the
     price decays but liquidations stay enabled), then writeOff fires.
  Debug replay: before the write-off `supply = 576805532797118723576488134`,
  `paid = 576805532797118723576488134`, ledger TRUE (single borrower, zero
  free debt, zero reserves); after, `paid = 0`, `supply` unchanged,
  `loc = 12495208464770593466978`, `glo = 126214226916874681484`, ledger
  FALSE — the entire Coin supply is unbacked.

### CONFIRMED finding (HIGH): `writeOff` on the sole remaining debtor deletes debt without burning Coin

- Location: `src/Lender.sol::writeOff` (lines 302-332), `decreaseDebt`
  (lines 422-450).
- Mechanism: `writeOff` is **permissionless** (no access control). When a
  borrower is 100× undercollateralized (`debt > collateralValue * 100`,
  line 313) and liquidations are enabled, it (1) `decreaseDebt(borrower,
  type(uint).max)` — deletes the borrower's whole debt and its shares but
  **burns no Coin** (line 315), then (2) redistributes that debt to the
  remaining debtors via the pool totals — **but only `if (totalDebt > 0)`**
  (line 318). When the write-off target is the *sole remaining debtor* the
  redistribution block is skipped and the debt simply vanishes while Coin
  supply stays put. The identity `supply == freeDebt + paidDebt - reserves`
  breaks permanently: the Coin is unbacked.
- Reachability (no extreme setup needed): the harness counterexample is a
  single borrower at the honest $1800 price whose borrow succeeds (ledger
  TRUE), then ~30h of time with no feed update — inside the staleness unwind
  window `getCollateralPrice` decays the price toward 0 while `allowLiquidations`
  stays **true** (the staleness branch sets only `reduceOnly`, not
  `allowLiquidations`) — so anyone can call `writeOff(borrower, themselves)`,
  collect the borrower's full collateral, and leave Coin permanently unbacked.
  Also reachable via a >99% price collapse in a single-borrower market.
- Impact: protocol insolvency — minted Coin permanently exceeds its backing;
  redemption requires free debt, so the unbacked supply cannot be burned.
- Class: cross-function ledger accounting (delete-without-burn on a special
  case). Static-invisible: none of the 26 run3 findings targets this branch —
  run3's `Lender.sol:326` Reentrancy flag is the `collateral.safeTransfer`
  CEI order inside the same function, a different issue; the ledger break is
  not a reentrancy.

### Secondary note (low, availability): getters overflow at extreme interest-inflated debt
- solmate `mulDivDown` (FixedPointMathLib.sol:44) reverts when
  `shares * totalDebt` overflows uint256. With the operator's allowed 12h
  minimum half-life and long warps, interest compounds debt astronomically
  (observed `totalPaidDebt = 1.4e54`, `paidDebtShares = 1.66e26`; product
  2.3e80 > 2^256). At that point the protocol's own `getDebtOf` — used
  internally by `adjust`/`liquidate`/`setRedemptionStatus` — and
  `getRedeemAmountOut` revert (availability DoS on astronomically inflated
  positions). Not a ledger break (the interest is held in the reserve
  accounts, which the coin-ledger identity subtracts). Requires unrealistically
  long undercollateralized positions, so low severity. The handler now
  try/catch-wraps these reads so handler functions never revert; the 4 holding
  invariants still run 150k calls with 0 handler reverts.

### Cross-reference with run3 static findings (monolith-market, 26 findings)
| # | Detector | File:line | Verdict | Why |
|---|----------|-----------|---------|-----|
| 1-3,16,19 | AccessControl | ERC4626.sol:60/73/95, Lender.sol:260/339 | DISMISSED | `deposit`/`mint`/`redeem` (ERC4626) and `liquidate`/`redeem` are permissionless-by-design entry points (any receiver, liquidation/redemption incentives). All five are fuzz actions; every ledger identity holds across them. |
| 13-15,17,18,21,23,24 | Reentrancy | Lender.sol:141/174/286/326/347/388/602/609, Factory.sol:154 | DISMISSED | CEI-pattern flags. 141/388 are pure internal accounting (no external calls); 174/286/326/347 are `safeTransfer`/`transferFrom` on standard ERC20s (no callbacks) — the fuzzer runs them thousands of times with all ledger identities green; 602/609 (`pullLocalReserves`/`pullGlobalReserves`) zero the reserve after `coin.mint` — an order smell, but `coin.mint` has no external call so it cannot reenter, and `checkCoinLedger`/`checkLenderHoldsNoCoin` hold across all reserve pulls; Factory:154 is the one-time CREATE3 deploy. |
| 5-7,9,12,22,25 | ZeroAddress | Factory.sol:71/85/95, Vault.sol:19, Lender.sol:80/585, Coin.sol:10 | DISMISSED | Constructor params and operator-only setters (`setPendingOperator`, `setFeeRecipient`, CREATE3 address computation); deployer/operator-controlled inputs with no third-party state-machine consequence. |
| 4,10 | FrontRunning | ERC20.sol:68 (approve), Vault.sol:60 | DISMISSED | SWC-114 approve overwrite (pattern-TP; needs a racing malicious spender — the harness uses max approvals); Vault `deposit` has no slippage to front-run (exact share price, MIN_SHARES inflation guard smoke-pinned). |
| 11 | MEV | Vault.sol:60 | DISMISSED | ERC4626 deposit/withdraw at the exact share price with no oracle — nothing to sandwich. |
| 0,20 | ValueFlow | ERC4626.sol:48, Lender.sol:346 | DISMISSED | Both require fee-on-transfer/rebase tokens. Coin and the vault asset are protocol-own standard ERC20s; the exact share-book and coin-ledger invariants would catch any balance-vs-book divergence. |

Verdict: **26/26 DISMISSED** (9 Reentrancy HIGH, 5 AccessControl HIGH, 7
ZeroAddress, 2 FrontRunning, 2 ValueFlow, 1 MEV). None of the 26 corresponds
to the confirmed `writeOff` ledger bug — it lives in the one special-case
branch (the sole-debtor redistribution skip) that static patterns cannot see,
and which the exact coin-ledger identity is uniquely positioned to catch.

## Status (session 20)
- monolith-market: Lender/Vault lending-market harness. 4/5 invariants HOLD
  (150k calls/invariant, 0 reverts on seeds 42/1337), 8/8 smoke tests.
  **CONFIRMED finding #3 (HIGH): `Lender.writeOff` on the sole remaining
  debtor deletes debt without burning Coin → permanently unbacked Coin.**
  Stable 2-call counterexample (`combinedBorrow` → `attemptWriteOff`), reached
  through the oracle-staleness unwind window (25–49h stale, liquidations still
  enabled) or a >99% price collapse in a single-borrower market; not in run3
  (all **26/26 run3 monolith findings DISMISSED** — they are CEI-pattern
  reentrancy flags, permissionless-by-design AccessControl, governance
  ZeroAddress, approve/MEV, and fee-on-transfer ValueFlow, none of which is
  the ledger break). Secondary low note: `getDebtOf`/`getRedeemAmountOut`
  mulDiv-overflow DoS at extreme interest-inflated debt.
- Total: **3 CONFIRMED static-invisible findings across 11 protocols**
  (basis-cash Boardroom phantom rewards, harvest-ousd yield-delegation
  fund-lock, monolith writeOff unbacking); eight clean high-value harnesses
  (credit-guild, compound-v2, hundred-bond, balancer-v2, ionic-protocol,
  rocket-pool, morpho-blue, compound-v3), of which rocket-pool and morpho-blue
  pass echidna cross-checks; **18/18 run3 ionic findings CONFIRMED** and
  **116/116 run3 findings across the other 8 harnessed protocols DISMISSED**
  (credit-guild 41, compound-v2 7, balancer-v2 19, rocket-pool 3, morpho-blue
  7, compound-v3 13, monolith 26; hundred-bond 0).

# Protocol 12: kpk (KpkShares fund-vault) — session 21, 2026-08-05

Harness: `invariant_projects/kpk/`. solc 0.8.24 pinned (vendored OZ v5.0.0
needs ^0.8.20), evm paris, via_ir, optimizer 200. No forge-std; raw
StdInvariant ABI. Source vendored verbatim: `kpkShares.sol` (1,145 lines),
`KpkOivFactory.sol`, `IkpkShares.sol`, `FeeModules/`, `interfaces/`, `utils/`,
plus OZ at `lib/` (pruned to the 24 files the imports actually resolve).

## Setup
- UUPS proxy: `ERC1967Proxy` implementation `KpkShares`; `initialize` pranked
  as ADMIN (base asset USDC 6dp, price $1e8; SAFE = 0x5000 prefunded with
  standing max allowance; MockPerfFeeModule; management 5% / redemption 1% /
  performance 2%, TTLs 1 day).
  OPERATOR role granted as ADMIN; `updateAsset` (WETH 18dp @$3000e8, SPARE
  18dp) as OPERATOR.
- 6 actors prefunded 1M per asset, max-approved. All protocol calls via
  low-level call with swallowed revert (`fail_on_revert=false`); handler never
  reverts. `VM.warp(block.timestamp + amount % 7 days)` tick before most
  actions. Shadow request book biases selection toward valid pending requests
  via `staticcall` to `getRequest` (stale entries → known
  `RequestIdDoesNotExist`, swallowed).
- processAction uses settled-price ±10% (180-entry band) with a rare 1/8 wild
  price; min-shares factors 20%..150% of estimated output so most approvals
  succeed; wild/miscalibrated ones revert and are swallowed. Price deviation
  keeps `processAction` asset-agnostic across all 3 assets.

## Invariants (exact ledger identities) — BOTH HOLD
1. `invariant_shareBook`: `totalSupply() == balanceOf(vault) + balanceOf(feeReceiverA)
   + balanceOf(feeReceiverB) + Σ_actors balanceOf(actor)`.
2. `invariant_assetEscrow`: for each of the 3 assets,
   `asset.balanceOf(vault) == subscriptionAssets[asset]`.

Results:
- runs=200/depth=120: 2/2 PASS (24k calls/invariant, ~1.9k swallowed reverts).
- runs=500/depth=300: **2/2 PASS, 150k calls/invariant, ~11.5k swallowed
  reverts** — on seeds default, 1337, 42. (500/300 exercised via a temporary
  foundry.toml edit; `--fuzz-runs`/`--fuzz-depth` CLI flags and
  `FOUNDRY_*` env overrides do not exist / do not take effect on forge 1.7.1.)
- Swallowed reverts are the price-deviation / expiry-auto-reject /
  TTL-guard paths — expected; the identity invariants held throughout.

## Pricing scale (session learning, cost several smoke runs)
- Two mulDiv-Floor steps: `assetsValue = amount * 1e36 / price` then
  `shares = assetsValue * 1e8 / (10^assetDec * 1e18)` ⇒
  `shares = amount * 1e26 / (price * 10^assetDec)` (floor at each step).
- Base 6dp: $1 (1e6 USDC units) @ 1e8 → **1e24 shares**. Shares are a
  18-dec token priced at 1e8 USD ⇒ 1e24 shares/$1.
- Alt 18dp: 3e18 WETH @ 3000e8 → 3e18·1e26/3e29 = **1e15 shares** (asset and
  share decimals cancel — the naive `assetsToShares(1e18) → 1e18` read was
  wrong, and `minShares 1e18` there made the guard revert
  `RequestPriceLowerThanOperatorPrice`).

## Smoke suite (10/10 PASS)
subscription roundtrip (1e6 USDC → 1e24 shares, escrow book + SAFE transfer +
ledger), redemption roundtrip (1e24 shares → 990000e6 USDC + 1e22 share fee to
feeReceiver, no time elapsed), alt-asset subscription (3e18 WETH → 1e15
shares), both TTL-gated cancels (`RequestNotPastTtl` then status CANCELLED +
funds/shares returned), expired-request auto-reject, mgmt (5%) + perf (2%)
fees after 365d → exactly 7e22 shares to feeReceiver, recover-assets incl. the
escrow gate (0 recoverable while `subscriptionAssets[token] > 0`), pricing
floor round-trip baseline (`assetsToShares(1e12, 1e8) == 1e24`), and the
permission/guard matrix (expectRevert on `RequestPriceLowerThanOperatorPrice`
with an absurd 1e30 min-shares, plus admin/operator-only setters).

## Cross-reference with run3 static findings (kpk, 56 findings = 14 unique × 4 chains)
| Detector | File:line | Verdict | Why |
|----------|-----------|---------|-----|
| Reentrancy HIGH | kpkShares.sol:1056 | DISMISSED | CEI-pattern on `_updateAsset`: read-only `IERC20Metadata.symbol()/decimals()` calls then `_approvedAssets.push`. Operator-only entry, metadata calls cannot reenter, no callback receiver. updateAssetAction ran ~16k times/run with 0 reverts and both ledgers green. |
| ValueFlow | kpkShares.sol:231 | DISMISSED | `subscriptionAssets[asset] += assetsIn` after `transferFrom` — the classic balance-vs-ledger divergence flag, but it requires fee-on-transfer/rebase tokens. `invariant_assetEscrow` (exact physical == book for 3 assets) held across 150k calls — any divergence would fail it. |
| ZeroAddress | kpkShares.sol:217 | DISMISSED | `requestSubscription` param: `_approvedAssetsMap[address(0)].canDeposit` is false → reverts `NotAnApprovedAsset` (no reachable path). |
| ZeroAddress | kpkShares.sol:665 | DISMISSED | `_initializeState` params (init/constructor class): safe/feeReceiver set once at deploy by admin; SafeERC20 transfer to 0 would revert for the safe. |
| ZeroAddress | kpkShares.sol:772 / 799 | DISMISSED | `_approve/_rejectSubscriptionRequest` read request-struct addresses created under `_requireValidRequestParams`; no user-controlled zero-address state path. |
| ZeroAddress | kpkShares.sol:1102 / 1141 | DISMISSED | Admin/internal setters `_setFeeReceiver`/`_setPerformanceFeeModule`; zero feeReceiver mints fees to address(0) (= burn, governance choice), zero perf module is an admin setter. |
| Timestamp | kpkShares.sol:269 / 383 | DISMISSED | Intentional TTL gates: `cancelSubscription`/`cancelRedemption` revert `RequestNotPastTtl` until `timestamp + ttl` — the documented SWC-116 gating design, LOW class. Smoke-pinned both the reject-before-TTL and the allow-after-TTL behavior; expiry auto-reject separately verified. |
| StorageCollision | KpkOivFactory.sol:76 / kpkShares.sol:22 | DISMISSED | Both flag contract declaration lines (`is Ownable, ReentrancyGuard` / `is Initializable, UUPSUpgradeable, ...`) — the UUPS/inherited-storage class seen in every harness (rank score-1 class). |
| IntegerOverflow | ERC20Upgradeable.sol:230 / 235 | DISMISSED | Vendored OZ `balanceOf[from] -= amount` / `+=` in `_transfer`/mint, guarded by `require(balanceOf[from] >= amount)`. Library-level standard FP. |

Verdict: **14/14 unique DISMISSED** (56 incl. 4-chain dupes). The exact
`shareBook` + `assetEscrow` identities held across 150k calls with full
coverage of every flagged function (request flows, process/approve/reject,
cancels, fee accrual, recover, asset admin). None corresponds to a reachable
ledger break.

## Status (session 21)
- kpk: UUPS-proxy fund-vault harness. 2/2 invariants HOLD (150k calls/invariant
  on 3 seeds), 10/10 smoke tests. **No new finding.**
- Total: **3 CONFIRMED static-invisible findings across 12 protocols**
  (basis-cash Boardroom, harvest-ousd yield-delegation, monolith writeOff);
  nine clean high-value harnesses; **18/18 run3 ionic findings CONFIRMED** and
  **142/142 run3 findings across the other 9 harnessed finding-bearing
  protocols DISMISSED** (credit-guild 41, compound-v2 7, balancer-v2 19,
  rocket-pool 3, morpho-blue 7, compound-v3 13, monolith 26, kpk 56;
  hundred-bond 0). Analyzer untouched; pytest 21 passed / corpus 138/138.
- All 4 chains of run3 kpk are the same 14 unique findings (56 = 14×4); the
  harness used the Optimism copy as source of truth.

### Protocol 12 cross-check: Echidna on the kpk harness (session 22)

`test/EchidnaKpk.sol` (composition wrapper over `KpkHandler`, the rocket-pool/
morpho-blue pattern — forwards the 9 fuzz actions, exposes the 2 ledger
identities as `echidna_share_book` / `echidna_asset_escrow` view properties)
+ `echidna.yaml` (testMode property, testLimit 50000, seqLen 100, whitelist of
the 9 forwarded fuzz actions). echidna 2.3.3 with crytic-compile 0.4.2
(recreated venv at `/tmp/opencode/echidna_venv`; pip needed the mitmproxy CA
cert: `--cert ~/.mitmproxy/mitmproxy-ca-cert.pem`). solc 0.8.24 wired into
solc-select offline by copying the local `solc_versions/solc-0.8.24` binary
into `~/.solc-select/artifacts/solc-0.8.24/solc-0.8.24` and setting
`global-version` to 0.8.24. Compiled through crytic-compile's solc framework
on the single wrapper file with `--compile-force-framework solc` (crytic-compile
auto-applies the foundry.toml remappings, so the `@openzeppelin/contracts/`
imports resolve without explicit `--solc-remaps`).

Results (3 seeds):
- default, 12345, 5539492503410371496 (the morpho cross-check seed):
  **2/2 properties passing** each run (~50.1-50.3k tests/run, 100-deep
  sequences, ~50k calls, cov 18964-19419 instr, 6 codehashes, corpus 15-20).

```
echidna_share_book: passing
echidna_asset_escrow: passing
Unique instructions: 18991
Unique codehashes: 6
Corpus size: 17
Seed: 5539492503410371496
Total calls: 50210
```

**2/2 properties passing.** The exact share-book and asset-escrow identities
hold under echidna's byte-level calldata fuzzing too, independently
confirming the foundry 150k-call/3-seed runs and the 56/56 run3 kpk
dismissals. Both fuzzing engines agree: the kpk fund-vault ledger is sound.
