# Phase 3 — Invariant testing results

Date: 2026-08-04 (Phase 3 session 1)

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
