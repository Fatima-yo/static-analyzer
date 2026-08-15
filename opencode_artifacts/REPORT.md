# Analyzer findings report — 22 protocol corpus

Generated: 2026-08-03

> **Phase 3 addendum #12 (2026-08-05, session 21)**: final protocol of the
> run3 sweep — **kpk** (Onchain Investment Vehicles `KpkShares` fund-vault,
> 1,145 lines + `KpkOivFactory`; solc 0.8.24, vendored OZ v5.0.0). Harness
> `invariant_projects/kpk/` deploys the vault behind a UUPS proxy, pranks
> `initialize` as ADMIN (USDC base at $1, SAFE 0x5000, mock perf module, mgmt
> 5% / redemption 1% / perf 2%, 1-day TTLs), grants OPERATOR and adds WETH/
> SPARE assets, then fuzzes the full request lifecycle — subscription /
> redemption requests, operator process/approve/reject with a ±10%
> settled-price band and rare wild price, TTL-gated cancels, expiry
> auto-reject, fee accrual, recover-assets, asset admin — through a shadow
> request book that biases toward valid pending requests. Result: **2/2 exact
> ledger invariants HOLD** (`totalSupply == Σ balances` over vault escrow +
> fee receivers + actors; `asset.balanceOf(vault) == subscriptionAssets[asset]`
> for all 3 assets) at 200/120 and 500/300 (**150k calls/invariant, 3 seeds**,
> ~11.5k swallowed reverts = price-deviation/expiry/TTL guards); 10/10 smoke
> tests pass after re-pinning the share scale (shares = assets·1e26/
> (price·10^assetDec) ⇒ $1 @1e8 = **1e24 shares** for the 6dp base but 3 WETH
> @3000e8 = **1e15 shares** for the 18dp asset — the naive 1e18 expectations
> made the min-shares guard fire). **All 56/56 run3 kpk findings DISMISSED**
> (14 unique × 4 chains): the Reentrancy HIGH (kpkShares:1056) is the
> CEI-pattern `_updateAsset` (read-only `symbol()/decimals()` then
> `_approvedAssets.push`, operator-only, ~16k fuzz calls with 0 reverts); the
> ValueFlow (231) transfer-then-ledger `+=` is refuted by the exact assetEscrow
> identity across 150k calls (standard-ERC20 assumption); ZeroAddress
> (217/665/772/799/1102/1141) are init/admin/request-struct classes (zero asset
> fails `NotAnApprovedAsset`; feeReceiver=0 mints to 0 = burn); Timestamp
> (269/383) are the intentional `RequestNotPastTtl` gates; StorageCollision
> (factory:76, kpkShares:22) are contract-declaration UUPS/inherited-storage
> class; IntegerOverflow (OZ lib 230/235) are `require(balanceOf>=amount)`-
> guarded. Full writeup + pricing walkthrough: `invariant_results.md`.

> **Phase 3 addendum #11 (2026-08-05, session 20)**: eleventh protocol —
> **monolith-market** (Lender/Vault/Factory/Coin lending market, solc 0.8.13,
> solmate deps). Harness `invariant_projects/monolith-market/` vendored the
> full stack verbatim, set the 1% factory fee before `factory.deploy`, and
> fuzzed 19 actions (borrow/liquidate with 0.1%–100% price shocks, redeem,
> vault ERC4626 flows, stale-oracle warps, fee/ratio setters, reserve pulls)
> against 5 exact ledger invariants. Result: **4/5 HOLD** at 200/120 and 500/300
> (150k calls, 0 reverts, seeds 42/1337), 8/8 smoke pass. The 5th
> (invariant_coinLedger: `supply == freeDebt + paidDebt − reserves`) **FAILS on
> a CONFIRMED HIGH protocol bug**: permissionless `Lender.writeOff` on the sole
> remaining debtor deletes the debt with no Coin burn — the redistribution
> branch is gated on `totalDebt > 0` (Lender.sol:318), so a single-borrower
> write-off (via oracle staleness inside the 49h unwind window, or a >99% price
> collapse) permanently unbacks the Coin supply. **NOT in run3** — this is a
> static-invisible control-flow special case. **All 26/26 run3 monolith
> findings DISMISSED** (CEI-pattern reentrancy flags, permissionless-by-design
> AccessControl, governance ZeroAddress, approve/MEV, fee-on-transfer
> ValueFlow). Full writeup + per-finding table: `invariant_results.md`.

> **Phase 3 addendum #10 (2026-08-05, sessions 18-19)**: tenth protocol —
> **compound-v3 Comet** (`CometWithExtendedAssetList`, solc 0.8.15). Harness
> `invariant_projects/compound-v3/` configured USDC base + WETH/WBTC collateral
> markets with `borrowPerYearInterestRateBase = 0.04e18` (makes reserve growth
> structurally non-negative) and fuzzed supply/withdraw/transfer/absorb (oracle
> shocked)/buyCollateral/pause/warp. Result: **7/7 invariants HOLD** (base and
> collateral books, no-leak reserves, per-action residual ≥ −DUST, absorb
> debt-bound, solvency) at 200/120 and 500/300 (150k calls, 0 reverts, 4 seeds);
> 7/7 smoke pass. Three naive invariants were root-caused into the real
> protocol behavior: `totalSupply >= totalBorrow` is NOT Comet's solvency
> condition (both are present-value views), absorb can legitimately grow
> reserves (over-covered collateral + 1-unit index rounding), and non-absorb
> actions can move 1 base unit of principalValue floor-rounding dust.
> **All 13/13 run3 compound-v3 findings DISMISSED** (OracleManipulation/Taint =
> the shocked-price absorb surface pinned by the debt-bound/solvency
> invariants; internal ZeroAddress; delegatecall-extension SignatureReplay/
> storage). Full writeup: `invariant_results.md`.

> **Phase 3 addendum #9 (2026-08-05, sessions 15-17)**: ninth protocol —
> **morpho-blue** (Morpho lending ledger, solc 0.8.19). Harness
> `invariant_projects/morpho-blue/` wired two cross-token markets (USDC/WETH
> LLTV 86% fee 10%; WETH/USDC LLTV 80%) on mock IRM/oracle/ERC20s and fuzzed
> 12 actions including liquidations with oracle shocks. Result: **10/10
> invariants HOLD** at 200/120 and 500/300 (150k calls, 0 reverts), 8/8 smoke
> pass, plus an **echidna 2.3.3 cross-check: 10/10 properties passing** (50k
> calls, byte-level fuzzing). Surfaced and root-caused Morpho's **1-wei repay
> dust**: the virtual-share model lets a full-book-share repay overpay 1 wei
> into the pool, so the absolute balance-sheet identity is inexact and
> accumulating — the ledger invariant was reformulated as an exact per-action
> residual in {0,1}. **All 7/7 run3 morpho findings DISMISSED** (one-way-door
> ZeroAddress, non-fee-on-transfer ValueFlow, permissionless liquidate,
> EIP-712 sig-check, owner-whitelisted IRM read). Also root-caused a foundry
> invariant-fuzzer bug: it journals state for reverted calls
> (foundry_invariant.rs:547). Full writeup: `invariant_results.md`.

> **Phase 3 addendum #8 (2026-08-05, sessions 13-14)**: eighth protocol —
> **rocket-pool rETH** (token accounting, solc 0.8.24). Harness
> `invariant_projects/rocket-pool/` vendored the RocketTokenRETH/OzV1/OzV2
> oracle contracts, fuzzed deposit/mint/burn/swapTo/swapFrom/warp with a
> controllable oracle rate, and checked **4/4 exact conservation invariants**
> (totalSupply == Σ balances incl. the contract's own burn-fee escrow; ETH-in
> == collateral + pending). **All HOLD** at 200/120 and 500/300 (150k calls),
> 8/8 smoke pass, echidna cross-check green on 2 seeds. **All 3/3 run3 rETH
> findings DISMISSED** (FrontRunning/MEV on oracle-priced mint/burn guarded by
> `isValidOracle` + ETH reserves). Full writeup: `invariant_results.md`.

> **Phase 3 addendum #7 (2026-08-05, sessions 11-12)**: seventh protocol —
> **ionic-protocol** (Ionic lending markets, solc 0.8.10). Harness
> `invariant_projects/ionic-protocol/` vendored the core verbatim with three
> permission-neutralizing stubs (PoolLens / IonicUniV3Liquidator /
> AuthoritiesRegistry) at literal import paths, and fuzzed mint/redeem/borrow/
> repay/liquidate/repayBehalf/transfer through real Actor contracts (no
> cheatcode value flows) plus the admin-setter actions. Result: **3/3
> invariants HOLD** (cToken conservation exact, underlying conservation exact,
> borrow ledger within 1e9 rounding) at 200/120 and 500/300 (150k calls, 0
> reverts); 12/12 smoke pass. **All 18/18 run3 ionic findings CONFIRMED** — 16
> ZeroAddress are 8 unique owner-only setters (AddressesProvider +
> SafeOwnableUpgradeable, incl. `transferOwnership(0)` leaving the contract
> ownerless) that provably accept `address(0)` without revert (each
> smoke-pinned), plus 2 StorageCollision that are a documented latent upgrade
> hazard (a `pendingOwner` slot insert would shift every field on a plain-
> Ownable upgrade; benign from-genesis). Full writeup + per-setter table:
> `invariant_results.md`.

> **Phase 3 addendum #6 (2026-08-04, sessions 9-10)**: invariant testing on a
> sixth protocol — **balancer-v2 Vault** (`0xba1222...566bf2c8`, the protocol
> with the most run3 findings at 19 and the Phase-1 top-ranked flashLoan
> path). Harness `invariant_projects/balancer-v2/` vendors the full Vault
> corpus (solc 0.7.6) and drives a pure-ERC20 system — 3 MockERC20s, two
> constant-product MINIMAL_SWAP_INFO mock pools, a permissive authorizer, 3
> flash-loan recipients (repay / no-repay / under-repay) and 8 pranked
> actors — through swap/join/exit/flash-loan/internal-balance actions.
> Result: **all 8 invariants HOLD** (token conservation exact, vault-ledger
> exact, pool-share exact) at 200 and 1000 fuzz runs (300k calls per
> invariant); 8/8 smoke tests pass. No protocol flaw found. A teeth-check
> mutation (Vault physically receives internal-balance deposits but never
> credits the book) breaks all 3 ledger invariants, proving they can catch
> internal-accounting bugs. **All 19 run3 balancer-v2 findings DISMISSED**:
> the guarded `-`/`-=` paths in FlashLoans:77, PoolBalances:242/243,
> AssetTransfersHandler:72/131, UserBalance:193 and Swaps:411/412 were all
> exercised by the fuzzer (flash-loan no-repay/under-repay reverts hit the
> `BAL#515` guard atomically, ~1.3k swallowed reverts) with the ledger and
> conservation invariants green throughout; PoolRegistry bit-packing is
> bounded by construction; the 2 ZeroAddress are an authenticate-gated
> governance setter and a constructor-only param. Full writeup + per-finding
> table: `invariant_results.md`.

> **Phase 3 addendum #5 (2026-08-04, sessions 7-8)**: invariant testing on a
> fifth protocol — **hundred-finance HundredBond** (Polygon variant, solc
> 0.8.0, vendored OZ 4.4.1). Harness `invariant_projects/hundred-bond/` wires
> the owner-only `mint` (pulls HND backing 1:1 from the owner) / `burn`
> (returns HND to the owner) / `redeem` (burns HNDb and locks the user's HND
> into a mock veCRV-semantics `MockEscrow`) loop through a prank-routed handler
> with 8 actors (no `.value()` cheatcodes anywhere). Result: **all 3 invariants
> HOLD** — HNDb is backed 1:1 (`hnd.balanceOf(bond) == supply`), HNDb supply
> equals the sum of holder balances, and HND is conserved across
> owner/bond/escrow/actors (exactly 1M ether) — at 200 and 1000 fuzz runs
> (300k calls per invariant); 9/9 smoke tests pass. No protocol flaw in the v2
> path. Two design observations surfaced by the harness: (a) the **v1 escrow
> path** (`escrow_is_v2=false`) makes `redeem()` **always revert** against a
> veCRV-semantics escrow — it first `hnd.transfer`s the backing to the user,
> then asks the escrow to `deposit_for` the same amount from the bond with no
> `approve` (demonstrated by `test_v1_redeem_always_reverts`); (b) an exit via
> `burn` pays the **owner**, not the user, and a user whose escrow lock has
> expired can never `redeem` again (no re-lock path through the bond) — a
> design-fragility / UX note, not a loss. run3 `hundred-finance.json` = 0
> findings, so there is nothing to cross-check. Full writeup:
> `invariant_results.md`.

> **Phase 3 addendum #4 (2026-08-04, sessions 5-6)**: invariant testing on a
> fourth protocol — **compound-v2** (CEther money market). Harness
> `invariant_projects/compound-v2/` vendors the flattened 0.4.x `CEther.sol`,
> runs it against a permissive `SimpleComptroller` + White-Paper
> `SimpleInterestRateModel`, and fuzzes the whole mint / redeem / borrow / repay
> / repayBehalf / liquidate / transfer / transferFrom loop through **real
> on-chain Actor contracts** (8 actors, 1M ETH each, two markets). Result:
> **all 3 invariants HOLD** — cToken supply conservation (exact), underlying
> ETH conservation (exact, actors + markets + handler == 8e24), and the borrow
> ledger (per-account sum == totalBorrows within 1e9 wei) — at 200 and 1000
> fuzz runs and `--fuzz-runs 5000`; 9/9 smoke tests pass. No new finding; the 7
> run3 compound-v2 findings (SWC-114 approve pattern-TP, 3x governance
> ZeroAddress, 3x error-formatting IntegerOverflow) are all dismissed. The
> session also root-caused a **foundry prank+value revert leak**: a high-level
> `c.mint.value(x)()` under `vm.startPrank` can lose the pranked account's full
> balance when the call reverts under the invariant runner (reproduced as a 1e24
> fuzz-only violation, invisible to direct/outer-prank/low-level replays); fixed
> by moving every value-carrying operation into real Actor contracts (no value
> cheatcodes). Full writeup: `invariant_results.md`.

> **Phase 3 addendum #3 (2026-08-04, sessions 3-4)**: invariant testing on a
> third protocol — **credit-guild** (Ethereum Credit Guild lending loop).
> Harness `invariant_projects/credit-guild/` wires the full protocol (Core
> roles, ProfitManager, RateLimitedMinter, AuctionHouse, two EIP-1167
> LendingTerm clones) and fuzzes the whole borrow -> repay / call -> auction ->
> bid|forgive -> PnL loop plus gauge voting and rebasing. Result: **all 7
> invariants HOLD** (CREDIT/GUILD/collateral/gauge-weight/votes conservation,
> issuance consistency and caps) at 200, 1000, and 1500 fuzz runs; 9/9 smoke
> tests pass. No new finding — the first clean high-value harness. All 41 run3
> credit-guild findings were then cross-checked and **DISMISSED**: the 10 HIGH
> reentrancy reports (ERC20Gauges/ERC20MultiVotes) are internal pure state
> accounting with no external calls, the 2 HIGH Timestamp + BadRandomness are
> design-intent (block.timestamp is the protocol clock; the "random" loanId is
> an identifier), `distribute` is permissionless-by-design, and the rest are
> standard FPs — corroborated by the invariants holding across every gauge /
> votes / PnL sequence. Full writeup: `invariant_results.md`.

> **Phase 3 addendum #2 (2026-08-04, session 2)**: invariant testing extended
> to a second protocol and cross-checked with a second fuzzer.
> (a) **Echidna 2.3.3** independently reproduced the basis-cash Boardroom
> finding (identical shrunk 4-call counterexample). (b) **harvest OUSD** harness
> (`invariant_projects/harvest-ousd/`) found a **second CONFIRMED,
> analyzer-invisible flaw**: yield delegation + negative rebase underflows
> `balanceOf` on the delegation target (MEDIUM, fund-lock DoS) — the source's
> credits are frozen into the target at delegation, and a `changeSupply` shrink
> raises `rebasingCreditsPerToken_` until the target's `balanceOf` subtraction
> reverts, locking the account. Deterministic repros:
> `harvest-ousd/test/Findings.t.sol`. run3 harvest findings (SWC-114 approve,
> `_adjustAccount` reentrancy borderline-FP) are a different issue class — the
> accounting bug was invisible to static analysis. Full writeup:
> `invariant_results.md`.

> **Phase 3 addendum (2026-08-04)**: invariant testing on basis-cash
> (Phase 3, protocol 1) found a **CONFIRMED, analyzer-invisible accounting
> flaw**: Boardroom phantom/retroactive reward inflation on `withdraw`
> (MEDIUM, fund-lock DoS). The static analyzer has zero Boardroom findings in
> run3; the flaw is a cross-function arithmetic property only a fuzzer catches.
> Full writeup: `invariant_results.md`.

> **Phase 2 addendum (2026-08-04)**: this report documents the Phase 1 run over
> the original 22-protocol corpus (121 findings). After the solc coverage-gap
> fix the full 60-protocol TVL corpus was re-run: **44/60 protocols with
> findings, 447 total** (MEDIUM 303, HIGH 96, LOW 45, CRITICAL 3). Canonical
> ranking and verdicts are now in `ranked_findings.md/.json` (447, HIGH 178 /
> MED 205 / LOW 64) and `exploit_pocs/poc_verdicts.md` (Phase 2 section).
> All 21 new-detector HIGHs (ValueFlow 16, OracleTaint 5) plus top pre-existing
> HIGHs are DISMISSED; no confirmed exploits (consistent with the Phase 1 null
> result). The Phase 1 per-protocol detail below is retained for history.

## Methodology
- Current analyzer output: `newruns10/` (121 findings).
- Baseline: `run2/` triaged output of the legacy analyzer (113 findings).
- Corpus true-positive recall held at 138/138 = 100%; pytest 21 passed.
- Each finding below is tagged: baseline | pattern-TP | accepted SWC-116 gating | borderline FP | noise.

## Summary (n = 121)
| Detector | Count |
|----------|-------|
| ZeroAddress | 45 |
| IntegerOverflow | 35 |
| Timestamp | 9 |
| FrontRunning | 8 |
| AccessControl | 6 |
| MEV | 6 |
| StorageCollision | 6 |
| Reentrancy | 2 |
| OracleManipulation | 2 |
| SignatureReplay | 1 |
| CrossChain | 1 |

## Per-protocol findings

### basis-cash — 39 findings

**BACDAIPool.sol**
- ZeroAddress (MEDIUM) — line 113 — Function '' uses address parameter(s) [basisCash_, dai_] without a zero-address check.. _[baseline (triaged)]_
    `constructor(`
- Timestamp (LOW) — line 208 — block.timestamp used for randomness or time-based gating. _[accepted SWC-116 gating]_
    `function notifyRewardAmount(uint256 reward)`

**BACSUSDPool.sol**
- ZeroAddress (MEDIUM) — line 113 — Function '' uses address parameter(s) [basisCash_, susd_] without a zero-address check.. _[baseline (triaged)]_
    `constructor(`
- Timestamp (LOW) — line 208 — block.timestamp used for randomness or time-based gating. _[accepted SWC-116 gating]_
    `function notifyRewardAmount(uint256 reward)`

**BACUSDCPool.sol**
- ZeroAddress (MEDIUM) — line 113 — Function '' uses address parameter(s) [basisCash_, usdc_] without a zero-address check.. _[baseline (triaged)]_
    `constructor(`
- Timestamp (LOW) — line 208 — block.timestamp used for randomness or time-based gating. _[accepted SWC-116 gating]_
    `function notifyRewardAmount(uint256 reward)`

**BACUSDTPool.sol**
- ZeroAddress (MEDIUM) — line 113 — Function '' uses address parameter(s) [basisCash_, usdt_] without a zero-address check.. _[baseline (triaged)]_
    `constructor(`
- Timestamp (LOW) — line 208 — block.timestamp used for randomness or time-based gating. _[accepted SWC-116 gating]_
    `function notifyRewardAmount(uint256 reward)`

**BACyCRVPool.sol**
- ZeroAddress (MEDIUM) — line 113 — Function '' uses address parameter(s) [basisCash_, ycrv_] without a zero-address check.. _[baseline (triaged)]_
    `constructor(`
- Timestamp (LOW) — line 208 — block.timestamp used for randomness or time-based gating. _[accepted SWC-116 gating]_
    `function notifyRewardAmount(uint256 reward)`

**Boardroom.sol**
- ZeroAddress (MEDIUM) — line 41 — Function '' uses address parameter(s) [_cash, _share] without a zero-address check.. _[baseline (triaged)]_
    `constructor(IERC20 _cash, IERC20 _share) public {`

**Bond.sol**
- FrontRunning (MEDIUM) — line 30 — Function 'burn' moves funds or uses price data without slippage/deadline protection; may be vulnerable to front-running.. _[baseline (triaged)]_
    `function burn(uint256 amount) public override onlyOperator {`
- MEV (MEDIUM) — line 30 — Function 'burn' is an order- or price-sensitive operation without slippage/deadline protection.. _[baseline (triaged)]_
    `function burn(uint256 amount) public override onlyOperator {`

**Cash.sol**
- IntegerOverflow (MEDIUM) — line 13 — Potential integer overflow/underflow with operator '*'.. _[baseline (triaged)]_
    `_mint(msg.sender, 1 * 10**18);`
- FrontRunning (MEDIUM) — line 42 — Function 'burn' moves funds or uses price data without slippage/deadline protection; may be vulnerable to front-running.. _[baseline (triaged)]_
    `function burn(uint256 amount) public override onlyOperator {`
- MEV (MEDIUM) — line 42 — Function 'burn' is an order- or price-sensitive operation without slippage/deadline protection.. _[baseline (triaged)]_
    `function burn(uint256 amount) public override onlyOperator {`

**DAIBACLPTokenSharePool.sol**
- ZeroAddress (MEDIUM) — line 88 — Function '' uses address parameter(s) [basisShare_, lptoken_] without a zero-address check.. _[baseline (triaged)]_
    `constructor(`
- Timestamp (LOW) — line 189 — block.timestamp used for randomness or time-based gating. _[accepted SWC-116 gating]_
    `function notifyRewardAmount(uint256 reward)`

**DAIBASLPTokenSharePool.sol**
- ZeroAddress (MEDIUM) — line 87 — Function '' uses address parameter(s) [basisShare_, lptoken_] without a zero-address check.. _[baseline (triaged)]_
    `constructor(`
- Timestamp (LOW) — line 178 — block.timestamp used for randomness or time-based gating. _[accepted SWC-116 gating]_
    `function notifyRewardAmount(uint256 reward)`

**IRewardDistributionRecipient.sol**
- ZeroAddress (MEDIUM) — line 18 — Function 'setRewardDistribution' uses address parameter(s) [_rewardDistribution] without a zero-address check.. _[baseline (triaged)]_
    `function setRewardDistribution(address _rewardDistribution)`

**InitialCashDistributor.sol**
- AccessControl (HIGH) — line 33 — Function 'distribute' performs a privileged operation but lacks access control (no auth modifier or msg.sender/tx.origin check).. _[baseline (triaged)]_
    `function distribute() public override {`
- Reentrancy (HIGH) — line 42 — Potential reentrancy: external call is followed by a state modification (checks-effects-interactions violation).. _[pattern-TP (low exploitability)]_
    `cash.transfer(address(pools[i]), amount);`

**InitialShareDistributor.sol**
- ZeroAddress (MEDIUM) — line 22 — Function '' uses address parameter(s) [_share, _daibacLPPool, _daibasLPPool] without a zero-address check.. _[baseline (triaged)]_
    `constructor(`
- AccessControl (HIGH) — line 36 — Function 'distribute' performs a privileged operation but lacks access control (no auth modifier or msg.sender/tx.origin check).. _[baseline (triaged)]_
    `function distribute() public override {`
- Reentrancy (HIGH) — line 42 — Potential reentrancy: external call is followed by a state modification (checks-effects-interactions violation).. _[pattern-TP (low exploitability)]_
    `share.transfer(address(daibacLPPool), daibacInitialBalance);`

**MockDai.sol**
- IntegerOverflow (MEDIUM) — line 11 — Potential integer overflow/underflow with operator '*'.. _[baseline (triaged)]_
    `_mint(msg.sender, 10000 * 10**18);`

**Oracle.sol**
- AccessControl (HIGH) — line 49 — Function 'update' performs a privileged operation but lacks access control (no auth modifier or msg.sender/tx.origin check).. _[baseline (triaged)]_
    `function update() external {`
- IntegerOverflow (MEDIUM) — line 55 — Potential integer overflow/underflow with operator '-'.. _[baseline (triaged)]_
    `uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired`
- IntegerOverflow (MEDIUM) — line 65 — Potential integer overflow/underflow with operator '-'.. _[baseline (triaged)]_
    `uint224((price0Cumulative - price0CumulativeLast) / timeElapsed)`
- IntegerOverflow (MEDIUM) — line 68 — Potential integer overflow/underflow with operator '-'.. _[baseline (triaged)]_
    `uint224((price1Cumulative - price1CumulativeLast) / timeElapsed)`

**Share.sol**
- IntegerOverflow (MEDIUM) — line 10 — Potential integer overflow/underflow with operator '*'.. _[baseline (triaged)]_
    `_mint(msg.sender, 1 * 10**18);`
- FrontRunning (MEDIUM) — line 29 — Function 'burn' moves funds or uses price data without slippage/deadline protection; may be vulnerable to front-running.. _[baseline (triaged)]_
    `function burn(uint256 amount) public override onlyOperator {`
- MEV (MEDIUM) — line 29 — Function 'burn' is an order- or price-sensitive operation without slippage/deadline protection.. _[baseline (triaged)]_
    `function burn(uint256 amount) public override onlyOperator {`

**Timelock.sol**
- ZeroAddress (MEDIUM) — line 75 — Function '' uses address parameter(s) [admin_] without a zero-address check.. _[baseline (triaged)]_
    `constructor(address admin_, uint256 delay_) public {`
- ZeroAddress (MEDIUM) — line 120 — Function 'setPendingAdmin' uses address parameter(s) [pendingAdmin_] without a zero-address check.. _[baseline (triaged)]_
    `function setPendingAdmin(address pendingAdmin_) public {`

**Treasury.sol**
- ZeroAddress (MEDIUM) — line 50 — Function '' uses address parameter(s) [_cash, _bond, _share, _cashOracle, _boardroom] without a zero-address check.. _[baseline (triaged)]_
    `constructor(`
- Timestamp (LOW) — line 108 — block.timestamp used for randomness or time-based gating. _[accepted SWC-116 gating]_
    `function migrate(address target) public onlyOperator checkMigration {`
- Timestamp (LOW) — line 139 — block.timestamp used for randomness or time-based gating. _[accepted SWC-116 gating]_
    `function _allocateSeigniorage(uint256 cashPrice)`

### balancer-v2 — 19 findings

**AssetTransfersHandler.sol**
- IntegerOverflow (MEDIUM) — line 72 — Potential integer overflow/underflow with operator '-='.. _[baseline (triaged)]_
    `amount -= deductedBalance;`
- IntegerOverflow (MEDIUM) — line 131 — Potential integer overflow/underflow with operator '-'.. _[baseline (triaged)]_
    `uint256 excess = msg.value - amountUsed;`

**FlashLoans.sol**
- IntegerOverflow (MEDIUM) — line 77 — Potential integer overflow/underflow with operator '-'.. _[baseline (triaged)]_
    `uint256 receivedFeeAmount = postLoanBalance - preLoanBalance;`

**PoolBalances.sol**
- IntegerOverflow (MEDIUM) — line 242 — Potential integer overflow/underflow with operator '-'.. _[baseline (triaged)]_
    `? balances[i].increaseCash(amountIn - feeAmount)`
- IntegerOverflow (MEDIUM) — line 243 — Potential integer overflow/underflow with operator '-'.. _[baseline (triaged)]_
    `: balances[i].decreaseCash(feeAmount - amountIn);`

**PoolRegistry.sol**
- IntegerOverflow (MEDIUM) — line 82 — Potential integer overflow/underflow with operator '+='.. _[baseline (triaged)]_
    `_nextPoolNonce += 1;`
- IntegerOverflow (MEDIUM) — line 123 — Potential integer overflow/underflow with operator '*'.. _[baseline (triaged)]_
    `serialized |= bytes32(uint256(specialization)) << (10 * 8);`
- IntegerOverflow (MEDIUM) — line 124 — Potential integer overflow/underflow with operator '*'.. _[baseline (triaged)]_
    `serialized |= bytes32(uint256(pool)) << (12 * 8);`
- IntegerOverflow (MEDIUM) — line 137 — Potential integer overflow/underflow with operator '*'.. _[baseline (triaged)]_
    `return address(uint256(poolId) >> (12 * 8));`
- IntegerOverflow (MEDIUM) — line 147 — Potential integer overflow/underflow with operator '*'.. _[baseline (triaged)]_
    `uint256 value = uint256(poolId >> (10 * 8)) & (2**(2 * 8) - 1);`
- IntegerOverflow (MEDIUM) — line 147 — Potential integer overflow/underflow with operator '-'.. _[baseline (triaged)]_
    `uint256 value = uint256(poolId >> (10 * 8)) & (2**(2 * 8) - 1);`
- IntegerOverflow (MEDIUM) — line 147 — Potential integer overflow/underflow with operator '*'.. _[baseline (triaged)]_
    `uint256 value = uint256(poolId >> (10 * 8)) & (2**(2 * 8) - 1);`

**ProtocolFeesCollector.sol**
- ZeroAddress (MEDIUM) — line 57 — Function '' uses address parameter(s) [_vault] without a zero-address check.. _[baseline (triaged)]_
    `constructor(IVault _vault)`

**Swaps.sol**
- IntegerOverflow (MEDIUM) — line 411 — Potential integer overflow/underflow with operator '-='.. _[baseline (triaged)]_
    `indexIn -= 1;`
- IntegerOverflow (MEDIUM) — line 412 — Potential integer overflow/underflow with operator '-='.. _[baseline (triaged)]_
    `indexOut -= 1;`

**TemporarilyPausable.sol**
- IntegerOverflow (MEDIUM) — line 52 — Potential integer overflow/underflow with operator '+'.. _[baseline (triaged)]_
    `uint256 pauseWindowEndTime = block.timestamp + pauseWindowDuration;`
- IntegerOverflow (MEDIUM) — line 55 — Potential integer overflow/underflow with operator '+'.. _[baseline (triaged)]_
    `_bufferPeriodEndTime = pauseWindowEndTime + bufferPeriodDuration;`

**UserBalance.sol**
- IntegerOverflow (MEDIUM) — line 193 — Potential integer overflow/underflow with operator '-'.. _[baseline (triaged)]_
    `uint256 newBalance = currentBalance - deducted;`

**VaultAuthorization.sol**
- ZeroAddress (MEDIUM) — line 88 — Function '_setAuthorizer' uses address parameter(s) [newAuthorizer] without a zero-address check.. _[baseline (triaged)]_
    `function _setAuthorizer(IAuthorizer newAuthorizer) private {`

### ionic-protocol — 18 findings

**AddressesProvider.sol**
- StorageCollision (MEDIUM) — line 12 — Contract 'AddressesProvider' inherits from multiple state-bearing base contracts (SafeOwnableUpgradeable, OwnableUpgradeable, Initializable, Initializable, ContextUpgradeable, ContextUpgradeable, OwnableUpgradeable, SafeOwnableUpgradeable); verify storage layout ordering.. _[baseline (triaged)]_
    `contract AddressesProvider is SafeOwnableUpgradeable {`
- StorageCollision (MEDIUM) — line 12 — Contract 'AddressesProvider' inherits from multiple state-bearing base contracts (SafeOwnableUpgradeable, OwnableUpgradeable, Initializable, Initializable, ContextUpgradeable, ContextUpgradeable, OwnableUpgradeable, SafeOwnableUpgradeable); verify storage layout ordering.. _[baseline (triaged)]_
    `contract AddressesProvider is SafeOwnableUpgradeable {`
- ZeroAddress (MEDIUM) — line 65 — Function 'setFlywheelRewards' uses address parameter(s) [flywheelRewardsModule] without a zero-address check.. _[baseline (triaged)]_
    `function setFlywheelRewards(`
- ZeroAddress (MEDIUM) — line 65 — Function 'setFlywheelRewards' uses address parameter(s) [flywheelRewardsModule] without a zero-address check.. _[baseline (triaged)]_
    `function setFlywheelRewards(`
- ZeroAddress (MEDIUM) — line 79 — Function 'setPlugin' uses address parameter(s) [plugin] without a zero-address check.. _[baseline (triaged)]_
    `function setPlugin(`
- ZeroAddress (MEDIUM) — line 79 — Function 'setPlugin' uses address parameter(s) [plugin] without a zero-address check.. _[baseline (triaged)]_
    `function setPlugin(`
- ZeroAddress (MEDIUM) — line 93 — Function 'setRedemptionStrategy' uses address parameter(s) [strategy, outputToken] without a zero-address check.. _[baseline (triaged)]_
    `function setRedemptionStrategy(`
- ZeroAddress (MEDIUM) — line 93 — Function 'setRedemptionStrategy' uses address parameter(s) [strategy, outputToken] without a zero-address check.. _[baseline (triaged)]_
    `function setRedemptionStrategy(`
- ZeroAddress (MEDIUM) — line 112 — Function 'setFundingStrategy' uses address parameter(s) [strategy, inputToken] without a zero-address check.. _[baseline (triaged)]_
    `function setFundingStrategy(`
- ZeroAddress (MEDIUM) — line 112 — Function 'setFundingStrategy' uses address parameter(s) [strategy, inputToken] without a zero-address check.. _[baseline (triaged)]_
    `function setFundingStrategy(`
- ZeroAddress (MEDIUM) — line 150 — Function 'setAddress' uses address parameter(s) [newAddress] without a zero-address check.. _[baseline (triaged)]_
    `function setAddress(string calldata id, address newAddress) external onlyOwner {`
- ZeroAddress (MEDIUM) — line 150 — Function 'setAddress' uses address parameter(s) [newAddress] without a zero-address check.. _[baseline (triaged)]_
    `function setAddress(string calldata id, address newAddress) external onlyOwner {`
- ZeroAddress (MEDIUM) — line 170 — Function 'setBalancerPoolForTokens' uses address parameter(s) [pool] without a zero-address check.. _[baseline (triaged)]_
    `function setBalancerPoolForTokens(`
- ZeroAddress (MEDIUM) — line 170 — Function 'setBalancerPoolForTokens' uses address parameter(s) [pool] without a zero-address check.. _[baseline (triaged)]_
    `function setBalancerPoolForTokens(`

**SafeOwnableUpgradeable.sol**
- ZeroAddress (MEDIUM) — line 51 — Function '_setPendingOwner' uses address parameter(s) [newPendingOwner] without a zero-address check.. _[baseline (triaged)]_
    `function _setPendingOwner(address newPendingOwner) public onlyOwner {`
- ZeroAddress (MEDIUM) — line 51 — Function '_setPendingOwner' uses address parameter(s) [newPendingOwner] without a zero-address check.. _[baseline (triaged)]_
    `function _setPendingOwner(address newPendingOwner) public onlyOwner {`
- ZeroAddress (MEDIUM) — line 89 — Function 'transferOwnership' uses address parameter(s) [newOwner] without a zero-address check.. _[baseline (triaged)]_
    `function transferOwnership(address newOwner) public override onlyOwner {`
- ZeroAddress (MEDIUM) — line 89 — Function 'transferOwnership' uses address parameter(s) [newOwner] without a zero-address check.. _[baseline (triaged)]_
    `function transferOwnership(address newOwner) public override onlyOwner {`

### lido — 12 findings

**ACL.sol**
- OracleManipulation (HIGH) — line 347 — Chainlink oracle read detected without staleness/round validation. _[baseline (triaged)]_
    `value = getTimestamp();`
- ZeroAddress (MEDIUM) — line 455 — Function '_setPermissionManager' uses address parameter(s) [_newManager] without a zero-address check.. _[baseline (triaged)]_
    `function _setPermissionManager(address _newManager, address _app, bytes32 _role) internal {`

**ACLSyntaxSugar.sol**
- IntegerOverflow (MEDIUM) — line 92 — Potential integer overflow/underflow with operator '*'.. _[baseline (triaged)]_
    `return uint8(_x >> (8 * 30));`
- IntegerOverflow (MEDIUM) — line 96 — Potential integer overflow/underflow with operator '*'.. _[baseline (triaged)]_
    `return uint8(_x >> (8 * 31));`
- IntegerOverflow (MEDIUM) — line 101 — Potential integer overflow/underflow with operator '*'.. _[baseline (triaged)]_
    `b = uint32(_x >> (8 * 4));`
- IntegerOverflow (MEDIUM) — line 102 — Potential integer overflow/underflow with operator '*'.. _[baseline (triaged)]_
    `c = uint32(_x >> (8 * 8));`

**PublicResolver.sol**
- IntegerOverflow (MEDIUM) — line 166 — Potential integer overflow/underflow with operator '-'.. _[baseline (triaged)]_
    `if (((contentType - 1) & contentType) != 0) throw;`

**Repo.sol**
- IntegerOverflow (MEDIUM) — line 53 — Potential integer overflow/underflow with operator '-'.. _[baseline (triaged)]_
    `uint256 lastVersionIndex = versionsNextIndex - 1;`
- IntegerOverflow (MEDIUM) — line 82 — Potential integer overflow/underflow with operator '-'.. _[baseline (triaged)]_
    `return getByVersionId(versionsNextIndex - 1);`
- IntegerOverflow (MEDIUM) — line 108 — Potential integer overflow/underflow with operator '-'.. _[baseline (triaged)]_
    `return versionsNextIndex - 1;`
- IntegerOverflow (MEDIUM) — line 120 — Potential integer overflow/underflow with operator '-'.. _[baseline (triaged)]_
    `if (_oldVersion[i] > _newVersion[i] || _newVersion[i] - _oldVersion[i] != 1) {`

**TimeHelpers.sol**
- OracleManipulation (HIGH) — line 46 — Chainlink oracle read detected without staleness/round validation. _[baseline (triaged)]_
    `return getTimestamp().toUint64();`

### compound-v2 — 7 findings

**CEther.sol**
- FrontRunning (MEDIUM) — line 1131 — Function 'approve' overwrites an allowance without a zero-then-set first (SWC-114); the old spender can front-run the reset and spend the full amount.. _[pattern-TP (low exploitability)]_
    `function approve(address spender, uint256 amount) external returns (bool) {`
- ZeroAddress (MEDIUM) — line 2106 — Function '_setPendingAdmin' uses address parameter(s) [newPendingAdmin] without a zero-address check.. _[baseline (triaged)]_
    `function _setPendingAdmin(address payable newPendingAdmin) external returns (uint) {`
- ZeroAddress (MEDIUM) — line 2156 — Function '_setComptroller' uses address parameter(s) [newComptroller] without a zero-address check.. _[baseline (triaged)]_
    `function _setComptroller(ComptrollerInterface newComptroller) public returns (uint) {`
- ZeroAddress (MEDIUM) — line 2311 — Function '_setInterestRateModelFresh' uses address parameter(s) [newInterestRateModel] without a zero-address check.. _[baseline (triaged)]_
    `function _setInterestRateModelFresh(InterestRateModel newInterestRateModel) internal returns (uint) {`
- IntegerOverflow (MEDIUM) — line 2525 — Potential integer overflow/underflow with operator '+'.. _[baseline (triaged)]_
    `bytes memory fullMessage = new bytes(bytes(message).length + 5);`
- IntegerOverflow (MEDIUM) — line 2534 — Potential integer overflow/underflow with operator '+'.. _[noise (duplicate, pure helper)]_
    `fullMessage[i+2] = byte(uint8(48 + ( errCode / 10 )));`
- IntegerOverflow (MEDIUM) — line 2535 — Potential integer overflow/underflow with operator '+'.. _[noise (duplicate, pure helper)]_
    `fullMessage[i+3] = byte(uint8(48 + ( errCode % 10 )));`

### forta — 7 findings

**AccessManaged.sol**
- ZeroAddress (MEDIUM) — line 36 — Function '__AccessManaged_init' uses address parameter(s) [manager] without a zero-address check.. _[baseline (triaged)]_
    `function __AccessManaged_init(address manager) internal initializer {`
- ZeroAddress (MEDIUM) — line 56 — Function 'setAccessManager' uses address parameter(s) [newManager] without a zero-address check.. _[baseline (triaged)]_
    `function setAccessManager(address newManager) public onlyRole(DEFAULT_ADMIN_ROLE) {`

**FortaStaking.sol**
- StorageCollision (MEDIUM) — line 52 — Contract 'FortaStaking' inherits from multiple state-bearing base contracts (BaseComponentUpgradeable, ForwardedContext, ContextUpgradeable, Initializable, AccessManagedUpgradeable, RoutedUpgradeable, UUPSUpgradeable, ERC1967UpgradeUpgradeable, ERC1155SupplyUpgradeable, ERC1155Upgradeable, ERC165Upgradeable); verify storage layout ordering.. _[baseline (triaged)]_
    `contract FortaStaking is BaseComponentUpgradeable, ERC1155SupplyUpgradeable, SubjectTypeValidator, ISlashingEx`

**ForwardedContext.sol**
- ZeroAddress (MEDIUM) — line 14 — Function '' uses address parameter(s) [trustedForwarder] without a zero-address check.. _[baseline (triaged)]_
    `constructor(address trustedForwarder) {`

**RewardsDistributor.sol**
- StorageCollision (MEDIUM) — line 20 — Contract 'RewardsDistributor' inherits from multiple state-bearing base contracts (BaseComponentUpgradeable, ForwardedContext, ContextUpgradeable, Initializable, AccessManagedUpgradeable, RoutedUpgradeable, UUPSUpgradeable, ERC1967UpgradeUpgradeable); verify storage layout ordering.. _[baseline (triaged)]_
    `contract RewardsDistributor is BaseComponentUpgradeable, SubjectTypeValidator, IRewardsDistributor {`

**Routed.sol**
- AccessControl (HIGH) — line 21 — Function 'disableRouter' performs a privileged operation but lacks access control (no auth modifier or msg.sender/tx.origin check).. _[baseline (triaged)]_
    `function disableRouter() public {`

**StakeSubjectGateway.sol**
- StorageCollision (MEDIUM) — line 16 — Contract 'StakeSubjectGateway' inherits from multiple state-bearing base contracts (BaseComponentUpgradeable, ForwardedContext, ContextUpgradeable, Initializable, AccessManagedUpgradeable, RoutedUpgradeable, UUPSUpgradeable, ERC1967UpgradeUpgradeable); verify storage layout ordering.. _[baseline (triaged)]_
    `contract StakeSubjectGateway is BaseComponentUpgradeable, SubjectTypeValidator, IStakeSubjectGateway {`

### harvest-finance — 5 findings

**OUSD.sol**
- FrontRunning (MEDIUM) — line 404 — Function 'approve' overwrites an allowance without a zero-then-set first (SWC-114); the old spender can front-run the reset and spend the full amount.. _[pattern-TP (low exploitability)]_
    `function approve(address _spender, uint256 _value) external returns (bool) {`
- FrontRunning (MEDIUM) — line 414 — Function 'mint' moves funds or uses price data without slippage/deadline protection; may be vulnerable to front-running.. _[baseline (triaged)]_
    `function mint(address _account, uint256 _amount) external onlyVault {`
- MEV (MEDIUM) — line 414 — Function 'mint' is an order- or price-sensitive operation without slippage/deadline protection.. _[baseline (triaged)]_
    `function mint(address _account, uint256 _amount) external onlyVault {`
- FrontRunning (MEDIUM) — line 434 — Function 'burn' moves funds or uses price data without slippage/deadline protection; may be vulnerable to front-running.. _[baseline (triaged)]_
    `function burn(address _account, uint256 _amount) external onlyVault {`
- MEV (MEDIUM) — line 434 — Function 'burn' is an order- or price-sensitive operation without slippage/deadline protection.. _[baseline (triaged)]_
    `function burn(address _account, uint256 _amount) external onlyVault {`

### hegic — 3 findings

**ECDSAUpgradeable.sol**
- SignatureReplay (CRITICAL) — line 53 — Signature verification detected without replay protection. _[baseline (triaged)]_
    `function recover(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address) {`

**StandardArbERC20.sol**
- StorageCollision (MEDIUM) — line 29 — Contract 'StandardArbERC20' inherits from multiple state-bearing base contracts (L2GatewayToken, ERC20PermitUpgradeable, Initializable, ERC20Upgradeable, ContextUpgradeable, EIP712Upgradeable, Cloneable); verify storage layout ordering.. _[baseline (triaged)]_
    `contract StandardArbERC20 is IArbToken, L2GatewayToken, Cloneable {`
- CrossChain (HIGH) — line 43 — Cross-chain function 'bridgeInit' lacks access control.. _[baseline (triaged)]_
    `function bridgeInit(address _l1Address, bytes memory _data) public virtual {`

### rocket-pool — 3 findings

**RocketBase.sol**
- ZeroAddress (MEDIUM) — line 105 — Function '' uses address parameter(s) [_rocketStorageAddress] without a zero-address check.. _[baseline (triaged)]_
    `constructor(RocketStorageInterface _rocketStorageAddress) {`

**RocketTokenRETH.sol**
- FrontRunning (MEDIUM) — line 132 — Function 'burn' moves funds or uses price data without slippage/deadline protection; may be vulnerable to front-running.. _[baseline (triaged)]_
    `function burn(uint256 _rethAmount) override external {`
- MEV (MEDIUM) — line 132 — Function 'burn' is an order- or price-sensitive operation without slippage/deadline protection.. _[baseline (triaged)]_
    `function burn(uint256 _rethAmount) override external {`

### convex-finance — 2 findings

**ConvexToken.sol**
- ZeroAddress (MEDIUM) — line 1070 — Function '' uses address parameter(s) [_proxy] without a zero-address check.. _[baseline (triaged)]_
    `constructor(address _proxy)`
- AccessControl (HIGH) — line 1083 — Function 'updateOperator' performs a privileged operation but lacks access control (no auth modifier or msg.sender/tx.origin check).. _[baseline (triaged)]_
    `function updateOperator() public {`

### peer — 2 findings

**AddressGroupRegistry.sol**
- AccessControl (HIGH) — line 142 — Function 'removeMembers' performs a privileged operation but lacks access control (no auth modifier or msg.sender/tx.origin check).. _[baseline (triaged)]_
    `function removeMembers(bytes32 _groupId, address[] calldata _members) external override {`
- ZeroAddress (MEDIUM) — line 245 — Function '_createGroup' uses address parameter(s) [_curator] without a zero-address check.. _[baseline (triaged)]_
    `function _createGroup(address _curator, bool _isPublic, string memory _name) internal returns (bytes32 groupId`

### across — 1 findings

**PermissionSplitterProxy.sol**
- ZeroAddress (MEDIUM) — line 40 — Function '__setTarget' uses address parameter(s) [_target] without a zero-address check.. _[baseline (triaged)]_
    `function __setTarget(address _target) public onlyRole(DEFAULT_ADMIN_ROLE) {`

### sushiswap — 1 findings

**UniswapV2Router02.sol**
- ZeroAddress (MEDIUM) — line 409 — Function '' uses address parameter(s) [_factory, _WETH] without a zero-address check.. _[baseline (triaged)]_
    `constructor(address _factory, address _WETH) public {`

### uniswap-v3 — 1 findings

**PeripheryImmutableState.sol**
- ZeroAddress (MEDIUM) — line 14 — Function '' uses address parameter(s) [_factory, _WETH9] without a zero-address check.. _[baseline (triaged)]_
    `constructor(address _factory, address _WETH9) {`

### yearn-finance — 1 findings

**YFI.sol**
- ZeroAddress (MEDIUM) — line 211 — Function 'setGovernance' uses address parameter(s) [_governance] without a zero-address check.. _[baseline (triaged)]_
    `function setGovernance(address _governance) public {`

## Notes on categories
- **baseline (triaged)**: findings carried over from the legacy analyzer's triaged run — retained as accepted real findings.
- **NEW pattern-TP (4, low exploitability)**: basis-cash `InitialCashDistributor`/`InitialShareDistributor` `distribute()` — correct CEI-shape detection (`once=false` written after the transfer loop), but `Cash` is a standard OZ ERC20 with no callback and targets are trusted protocol contracts, so no practical re-entry vector. compound CEther `approve` + harvest OUSD `approve` — genuine SWC-114 allowance-overwrite instances (documented known pattern in Compound); low impact (requires a malicious spender racing a legitimate transaction).
- **accepted SWC-116 gating (9)**: basis-cash reward-epoch `block.timestamp` gates (pool `notifyRewardAmount` ×7, Treasury `migrate`/`_allocateSeigniorage` ×2). Benign in practice (governance-set windows) but the exact class the timestamp detector reports; aligned with corpus TPs.
- **borderline FP (2)**: harvest OUSD `_adjustAccount` reentrancy — internal credit-balance bookkeeping; the detected call is an internal read-only call chain (`balanceOf`/`_autoMigrate`/`_rebaseOptOut`), no external value transfer.
- **noise (2)**: compound CEther `fail()` index-arithmetic duplicates — pure error-formatting helper.
- **Removed vs baseline (2)**: basis-cash `Treasury.sol` `buyBonds` (FrontRunning + MEV, line 175) — exact-price pinning `require(cashPrice == targetPrice)` is genuine protection, so these FPs were dropped.

Per-protocol counts: basis-cash=39, balancer-v2=19, ionic-protocol=18, lido=12, compound-v2=7, forta=7, harvest-finance=5, hegic=3, rocket-pool=3, convex-finance=2, peer=2, across=1, sushiswap=1, uniswap-v3=1, yearn-finance=1