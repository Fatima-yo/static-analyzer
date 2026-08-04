# CONTINUE HERE — session state (saved 2026-08-04 ~after Phase 3 balancer-v2)

Resume point: Phase 3 protocol 6 (balancer-v2 Vault) is COMPLETE. The Vault
ledger harness is GREEN (8/8 invariants at 200 and 1000 runs, 8/8 smoke
tests); all 19 run3 balancer-v2 findings DISMISSED (guarded-subtraction paths
exercised green). Next = Phase 3 protocol 7 or an echidna pass over the newer
harnesses.

## Phase 3 status (6 protocols)
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
- balancer-v2: NO finding. 8/8 invariants HOLD (token conservation exact,
  vault-ledger exact, pool-share exact), 8/8 smoke tests pass, all 19 run3
  findings DISMISSED.

## balancer-v2 harness (sessions 9-10, this session's work)
- Path: `invariant_projects/balancer-v2/` (solc 0.7.6 binary pinned in
  foundry.toml, evm istanbul, optimizer runs=200). foundry.toml:
  `[invariant] runs=200 depth=120 fail_on_revert=false call_override=false`.
- Files: `src/` = full vendored Vault corpus (45 .sol, ^0.7.0 + ABIEncoderV2,
  relative imports intact); `test/MockERC20.sol`, `test/MockAuthorizer.sol`
  (permissive), `test/MockPool.sol` (constant-product MINIMAL_SWAP_INFO,
  registers itself), `test/FlashLoanRecipient.sol` (modes: repay /
  no-repay / under-repay), `test/BalancerHandler.sol` (8 actors 0x1111...0001-8,
  100k each token, max approval; swapGivenIn/Out, joinPool/exitPool, flashLoan,
  deposit/withdraw/transferInternal), `test/Invariants.t.sol`,
  `test/Smoke.t.sol` (8 tests).
- Verification: `forge test` = 16/16 pass (8 smoke + 8 invariants); invariants
  green at runs=1000/depth=300 (300k calls per invariant). High-run coverage:
  join/exit/swap ~37k calls each (0 reverts), flashLoan ~37k calls (~1.3k
  swallowed reverts = no-repay/under-repay recipients hitting `BAL#515`),
  internal ops ~37-38k (0 reverts).
- Lessons this session: (1) single-shot `vm.prank` gets consumed by
  argument-evaluation calls (`pool.poolId()`) before the Vault call, leaking
  the caller as msg.sender (`BAL#503`) — use `startPrank`/`stopPrank` around
  the whole call; (2) in 0.7, immutables cannot be read inside the
  constructor (use locals), `address payable` has no `payable()` cast, and
  unrelated contract types need explicit `address(...)` casts; (3) join/exit
  assets must match the pool's registered (address-sorted) order or the Vault
  reverts `TOKENS_MISMATCH`.
- Teeth-check: commenting out `_increaseInternalBalance` in
  `UserBalance.sol::_depositToInternalBalance` (Vault keeps the tokens, never
  credits the internal book) makes all 3 `vaultLedger_*` invariants FAIL in 50
  low-run passes (conservation stays green); restored -> green. The ledger
  invariant provably catches internal-accounting bugs.
- Analyzer untouched: pytest 21 passed, corpus 138/138 unaffected.

## Next steps (Phase 3 continued)
1. 7th protocol harness: lido (12 run3 findings, stETH rebasing + withdrawal
   queue) or ionic-protocol (18 findings) or rocket-pool (rETH oracle burn,
   Phase-1 top-ranked).
2. Optional: echidna 2.3.3 pass over the credit-guild / compound-v2 /
   hundred-bond / balancer-v2 harnesses (all pure-foundry right now).
3. If the next protocol finds nothing, widen a harness surface (multi-market
   collateral combos, interest-only rate models, reserve/claim paths) before
   moving to Phase 4.

## Key paths
- Analyzer: `/home/fatima/Downloads/static-analyzer` (venv `analyzer_env/`)
- Invariant harnesses: `invariant_projects/{basis-cash,harvest-ousd,credit-guild,compound-v2,hundred-bond,balancer-v2}/`
- Artifacts: `opencode_artifacts/{STATUS,ROADMAP,REPORT,invariant_results,CONTINUE_HERE}.md`
- run3 findings: `opencode_artifacts/run3/` (credit-guild.json 41, compound-v2 7,
  hundred-finance.json 0, balancer-v2.json 19)
- TVL corpus: `/home/fatima/Downloads/TVL/output_2026_08_01_22_58_07/full_code/<proto>/`
- Forge: `~/.config/.foundry/bin/forge` (1.7.1); Echidna: same dir (2.3.3)

## Historical context (Phases 1-2)
See `STATUS.md` (per-session log) and `REPORT.md` (addenda) for Phase 1
(ranking + PoC triage, null result), Phase 2 (solc coverage gap fixed -> 60
project re-run 44/60, 447 findings; all new-detector HIGHs triaged DISMISSED;
canonical artifacts = run3) and Phase 3 sessions 1-2 (basis-cash + harvest
OUSD CONFIRMED findings). Phase 3 sessions 3-4 (credit-guild), 5-6
(compound-v2), 7-8 (hundred-bond) and 9-10 (balancer-v2) are summarized in
the sections above.
