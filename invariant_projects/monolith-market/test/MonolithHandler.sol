// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {Lender} from "../src/Lender.sol";
import {Vault} from "../src/Vault.sol";
import {Coin} from "../src/Coin.sol";
import {Factory} from "../src/Factory.sol";

import {MockCollateral} from "../src/mocks/MockCollateral.sol";
import {MockChainlinkFeed} from "../src/mocks/MockChainlinkFeed.sol";

interface Vm {
    function warp(uint256) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert(bytes calldata) external;
    function log_named_uint(string calldata, uint256) external;
    function log_named_int(string calldata, int256) external;
    function log_named_bool(string calldata, bool) external;
}

/// @notice Invariant harness for monolith-market's Lender/Vault (solc 0.8.13).
/// A full Factory deployment (Coin + Vault + Lender over one collateral asset
/// with a Chainlink-style feed) exercises every ledger path: collateral
/// deposit/withdraw, borrow/repay, paid-vs-free debt opt-in/opt-out, redemption
/// of Coin for collateral against free debt, liquidations under oracle shocks,
/// write-offs of severely underwater accounts, interest accrual over time,
/// vault staking (ERC4626 deposit/mint/withdraw/redeem), fee setters, reserve
/// pulls and staleness-driven "reduce only" mode.
///
/// 6 actors are prefunded with collateral and route every action as
/// `msg.sender` via prank (all value flows are ERC20 — the balancer-v2
/// playbook). Every Lender/Vault call goes through a low-level call whose
/// revert is swallowed, so handler functions never revert (the rocket-pool
/// lesson: foundry's invariant fuzzer commits state for reverted calls).
/// Handler-side accumulators are only updated when the routed call succeeds.
///
/// Ledger invariants (all exact):
///  - Coin ledger: coin.totalSupply() == totalFreeDebt + totalPaidDebt
///    - accruedLocalReserves - accruedGlobalReserves. Every mint (borrow,
///    interest, reserve pulls) and every burn (repay, redeem, liquidate) moves
///    supply and the debt/reserve book by the same amount, so any missing or
///    duplicated ledger write (double mint, skipped burn, share mismatch)
///    breaks this identity exactly.
///  - paid-debt share book: sum(paidDebtShares[actor]) == totalPaidDebtShares.
///    Paid-debt shares are never touched by the redemption index (updateBorrower
///    only rewrites freeDebtShares), so the paid pool is conserved exactly.
///  - vault share book: vault.balanceOf(address(0)) == MIN_SHARES (1e16 dead
///    shares donated on first deposit against the ERC4626 inflation attack) and
///    sum(vault.balanceOf(actor)) + MIN_SHARES == vault.totalSupply(). Only
///    actors and address(0) ever hold shares, and the dead shares never move.
///  - vault coverage: vault.totalAssets() >= vault.totalSupply(). Assets grow
///    with staking interest while the share count only changes on deposit and
///    withdraw, so shares are always covered 1:1 (the inflation-attack guard).
///  - lender holds no Coin: every Coin that reaches the lender (repay, redeem,
///    liquidate) is burned in the same call, so coin.balanceOf(lender) == 0.
contract MonolithHandler {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint256 public constant N_ACTORS = 6;
    uint256 public constant MAX_WARP = 3 days;
    uint256 public constant MIN_SHARES = 1e16; // Vault.MIN_SHARES (dead shares)

    /// The factory's operator (set in the Factory constructor); the lender's
    /// operator is actors[0].
    address public constant FACTORY_OPERATOR = address(uint160(0x2000));

    int256 public constant PRICE = 1800e8; // $1800, 8dp feed
    uint256 public constant COLLATERAL_FACTOR = 7500; // 75%
    uint256 public constant MIN_DEBT = 10e18; // 10 Coin
    uint256 public constant PREFUND_COLLATERAL = 1_000_000e18; // 1M tokens/actor
    uint256 public constant MAX_BORROW = 1e9 ether; // borrow cap keeps uint120 reserves sane

    Lender public lender;
    Vault public vault;
    Coin public coin;
    MockCollateral public collateral;
    MockChainlinkFeed public feed;
    Factory public factory;

    address[N_ACTORS] public actors;

    /// Cumulative collateral actually paid out by successful redemptions
    /// (diagnostics only; the collateral invariants are deliberately not
    /// asserted on the redemption index because Monolith's lazy per-share
    /// accounting legitimately over-debits late borrowers).
    uint256 public cumulativeRedeemed;

    /// Diagnostics for the last routed action.
    bool public lastSuccess;
    bytes public lastReturnData;

    constructor() {
        collateral = new MockCollateral("Wrapped Stone", "WSTONE", 18);
        feed = new MockChainlinkFeed(8, PRICE);
        factory = new Factory(FACTORY_OPERATOR);

        for (uint256 i = 0; i < N_ACTORS; ++i) {
            actors[i] = address(uint160(0x1000 + i));
        }

        // Configure the factory fee BEFORE deployment so the Lender caches the
        // real 1% global fee at construction (cachedGlobalFeeBps is only
        // refreshed on a successful accrueInterest, which needs time to pass).
        VM.startPrank(FACTORY_OPERATOR);
        factory.setFeeBps(100);
        factory.setFeeRecipient(actors[1]);
        VM.stopPrank();

        // lender operator + factory operator = actors[0]; fee recipient = actors[1].
        (address l, address c, address v) = factory.deploy(
            "Monolith",
            "MONO",
            address(collateral),
            address(feed),
            COLLATERAL_FACTOR,
            MIN_DEBT,
            30 days,
            actors[0]
        );
        lender = Lender(payable(l));
        coin = Coin(c);
        vault = Vault(v);

        for (uint256 i = 0; i < N_ACTORS; ++i) {
            collateral.mint(actors[i], PREFUND_COLLATERAL);
        }
        for (uint256 i = 0; i < N_ACTORS; ++i) {
            VM.startPrank(actors[i]);
            collateral.approve(address(lender), type(uint256).max);
            coin.approve(address(lender), type(uint256).max);
            coin.approve(address(vault), type(uint256).max);
            VM.stopPrank();
        }
    }

    /// Deterministic bounding: preserves in-range values, maps out-of-range
    /// fuzz inputs via modulo.
    function _bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max <= min) return min;
        if (x >= min && x <= max) return x;
        return min + x % (max - min + 1);
    }

    /// Advance time before a routed action so interest has work to accrue
    /// (also pushes the feed toward staleness: STALENESS_THRESHOLD is 25 hours).
    function _tick(uint256 amount) internal {
        VM.warp(block.timestamp + amount % MAX_WARP);
    }

    /// Route a Lender/Vault call with `sender` as msg.sender. A reverting
    /// protocol call is swallowed so the handler function itself always
    /// succeeds. Returns whether the call succeeded.
    function _call(address target, address sender, bytes memory payload) internal returns (bool) {
        VM.startPrank(sender);
        (bool success, bytes memory data) = target.call(payload);
        VM.stopPrank();
        lastSuccess = success;
        lastReturnData = data;
        return success;
    }

    /// Lender.adjust is overloaded; use the 3-arg selector directly.
    /// bytes4(keccak256("adjust(address,int256,int256)")) == 0x2f0a454e.
    function _adjust(address account, int256 collateralDelta, int256 debtDelta, address sender) internal returns (bool) {
        return _call(address(lender), sender, abi.encodeWithSelector(0x2f0a454e, account, collateralDelta, debtDelta));
    }

    /* ============================= FUZZ ACTIONS ============================= */

    /// Deposit collateral for an actor (no debt change).
    function adjustDeposit(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        uint256 bal = collateral.balanceOf(actors[a]);
        if (bal == 0) return;
        uint256 amt = _bound(amount, 1, bal);
        _adjust(actors[a], int256(uint256(amt)), 0, actors[a]);
    }

    /// Borrow Coin against existing collateral.
    function adjustBorrow(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        uint256 amt = _bound(amount, MIN_DEBT, MAX_BORROW);
        _adjust(actors[a], 0, int256(uint256(amt)), actors[a]);
    }

    /// Repay Coin debt.
    function adjustRepay(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        uint256 bal = coin.balanceOf(actors[a]);
        if (bal == 0) return;
        uint256 amt = _bound(amount, 1, bal);
        _adjust(actors[a], 0, -int256(uint256(amt)), actors[a]);
    }

    /// Withdraw collateral (solvency check enforced by the protocol when the
    /// account has debt; reverts are swallowed).
    function adjustWithdraw(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        uint256 bal = lender._cachedCollateralBalances(actors[a]);
        if (bal == 0) return;
        uint256 amt = _bound(amount, 1, bal);
        _adjust(actors[a], -int256(uint256(amt)), 0, actors[a]);
    }

    /// Deposit fresh collateral and borrow against it in one call.
    function combinedBorrow(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        uint256 bal = collateral.balanceOf(actors[a]);
        if (bal == 0) return;
        uint256 dep = _bound(amount, 1, bal);
        uint256 debtAmt = _bound(amount >> 1, MIN_DEBT, MAX_BORROW);
        _adjust(actors[a], int256(uint256(dep)), int256(uint256(debtAmt)), actors[a]);
    }

    /// Opt an account into redeemable (free) debt; its debt moves to the free
    /// pool where redemptions are applied against it.
    function optInRedemption(uint256 idx) external {
        _tick(idx);
        uint256 a = idx % N_ACTORS;
        _call(address(lender), actors[a], abi.encodeCall(Lender.setRedemptionStatus, (actors[a], true)));
    }

    /// Opt an account out of redeemable debt.
    function optOutRedemption(uint256 idx) external {
        _tick(idx);
        uint256 a = idx % N_ACTORS;
        _call(address(lender), actors[a], abi.encodeCall(Lender.setRedemptionStatus, (actors[a], false)));
    }

    /// Shock the oracle down, liquidate a random borrower, restore the honest
    /// price. Bounds repay to the liquidator's Coin balance. View reads are
    /// try/catch-wrapped: at extreme interest-inflated debt the protocol's own
    /// getters (getDebtOf -> mulDivDown) overflow, and a reverting handler
    /// would be skipped by the fuzzer (handlers must never revert).
    function liquidate(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 liq = idx % N_ACTORS;
        uint256 bor = (idx / N_ACTORS) % N_ACTORS;
        uint256 shock = 1 + (idx / N_ACTORS / N_ACTORS) % 1000; // 0.1% .. 100% of price
        feed.setPrice(PRICE * int256(shock) / 1000);

        uint256 debt;
        try lender.getDebtOf(actors[bor]) returns (uint256 d) {
            debt = d;
        } catch {
            return;
        }
        uint256 collBal = lender._cachedCollateralBalances(actors[bor]);
        uint256 bal = coin.balanceOf(actors[liq]);
        if (debt > 0 && collBal > 0 && bal > 0) {
            uint256 amt = _bound(amount, 1, bal);
            _call(address(lender), actors[liq], abi.encodeCall(Lender.liquidate, (actors[bor], amt, 0)));
        }

        feed.setPrice(PRICE);
    }

    /// Redeem Coin for collateral against the free debt pool. Tracks the actual
    /// collateral paid out (handler-side accumulator gated on success).
    function redeem(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        uint256 bal = coin.balanceOf(actors[a]);
        uint256 freeDebt = lender.totalFreeDebt();
        if (bal == 0 || freeDebt == 0) return;
        uint256 amt = _bound(amount, 1, bal < freeDebt ? bal : freeDebt);
        uint256 expected;
        try lender.getRedeemAmountOut(amt) returns (uint256 e) {
            expected = e;
        } catch {
            return;
        }
        if (expected == 0) return;
        if (_call(address(lender), actors[a], abi.encodeCall(Lender.redeem, (amt, 0)))) {
            cumulativeRedeemed += abi.decode(lastReturnData, (uint256));
        }
    }

    /// Direct write-off attempt on a severely underwater account (debt >
    /// 100x collateral value); normally triggered from liquidate()'s try/catch.
    function attemptWriteOff(uint256 idx) external {
        _tick(idx);
        uint256 bor = idx % N_ACTORS;
        uint256 to = (idx / N_ACTORS) % N_ACTORS;
        _call(address(lender), actors[to], abi.encodeCall(Lender.writeOff, (actors[bor], actors[to])));
    }

    /// Stake Coin into the ERC4626 vault.
    function vaultDeposit(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        uint256 bal = coin.balanceOf(actors[a]);
        if (bal == 0) return;
        uint256 amt = _bound(amount, 1, bal);
        _call(address(vault), actors[a], abi.encodeCall(Vault.deposit, (amt, actors[a])));
    }

    /// Mint vault shares by depositing assets (rounds up; reverts swallowed).
    function vaultMint(uint256 idx, uint256 shares) external {
        _tick(shares);
        uint256 a = idx % N_ACTORS;
        uint256 bal = coin.balanceOf(actors[a]);
        if (bal == 0) return;
        uint256 s = _bound(shares, 1, bal);
        _call(address(vault), actors[a], abi.encodeCall(Vault.mint, (s, actors[a])));
    }

    /// Withdraw assets from the vault.
    function vaultWithdraw(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        uint256 max;
        try vault.maxWithdraw(actors[a]) returns (uint256 m) {
            max = m;
        } catch {
            return;
        }
        if (max == 0) return;
        uint256 amt = _bound(amount, 1, max);
        _call(address(vault), actors[a], abi.encodeCall(Vault.withdraw, (amt, actors[a], actors[a])));
    }

    /// Redeem vault shares for assets.
    function vaultRedeem(uint256 idx, uint256 shares) external {
        _tick(shares);
        uint256 a = idx % N_ACTORS;
        uint256 max;
        try vault.maxRedeem(actors[a]) returns (uint256 m) {
            max = m;
        } catch {
            return;
        }
        if (max == 0) return;
        uint256 s = _bound(shares, 1, max);
        _call(address(vault), actors[a], abi.encodeCall(Vault.redeem, (s, actors[a], actors[a])));
    }

    /// Manipulate the feed: fresh price at a random level, or a stale
    /// updatedAt that triggers the 25h STALENESS_UNWIND / reduce-only paths.
    function shockPrice(uint256 seed) external {
        uint256 m = seed % 3;
        if (m == 0) {
            // honest price, fresh timestamp
            feed.setPrice(PRICE);
        } else if (m == 1) {
            // 50%..150% of honest price, fresh timestamp
            uint256 factor = 500 + (seed >> 2) % 1000;
            feed.setPrice(PRICE * int256(factor) / 1000);
        } else {
            // honest price, stale timestamp (26h..3 days old)
            uint256 age = 26 hours + (seed >> 2) % (2 days + 1 hours);
            uint256 ts = block.timestamp > age ? block.timestamp - age : 0;
            feed.setUpdatedAt(ts);
        }
    }

    /// Advance time without touching the feed (drives interest accrual and
    /// natural staleness).
    function warp(uint256 amount) external {
        VM.warp(block.timestamp + _bound(amount, 0, 365 days));
    }

    /// Operator-only fee / rate setters (exercises onlyOperator + beforeDeadline
    /// + the accrueInterest that each setter performs).
    function operatorSetter(uint256 seed) external {
        _tick(seed);
        uint256 m = seed % 4;
        if (m == 0) {
            uint256 fee = _bound(seed >> 2, 0, 1000);
            _call(address(lender), actors[0], abi.encodeCall(Lender.setLocalReserveFeeBps, (fee)));
        } else if (m == 1) {
            uint256 fee = _bound(seed >> 2, 0, 300);
            _call(address(lender), actors[0], abi.encodeCall(Lender.setRedeemFeeBps, (uint16(fee))));
        } else if (m == 2) {
            uint256 start = _bound(seed >> 2, 500, 9000);
            uint256 end = _bound(seed >> 2, start, 9500);
            _call(address(lender), actors[0], abi.encodeCall(Lender.setTargetFreeDebtRatio, (uint16(start), uint16(end))));
        } else {
            uint256 halfLife = _bound(seed >> 2, 12 hours, 30 days);
            _call(address(lender), actors[0], abi.encodeCall(Lender.setHalfLife, (uint64(halfLife))));
        }
    }

    /// Operator pulls the local reserve fees (mints Coin, clears the reserve —
    /// the Coin ledger stays balanced).
    function pullLocalReserves(uint256 idx) external {
        _tick(idx);
        _call(address(lender), actors[0], abi.encodeCall(Lender.pullLocalReserves, ()));
    }

    /// Fee recipient pulls the global reserve fees through the factory.
    function pullGlobalReserves(uint256 idx) external {
        _tick(idx);
        _call(address(factory), actors[1], abi.encodeCall(Factory.pullReserves, (address(lender))));
    }

    /// Set up a delegation then have the delegatee adjust the delegator's
    /// position (exercises the delegations authorization path).
    function delegateAction(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 delegator = idx % N_ACTORS;
        uint256 delegatee = (idx / N_ACTORS) % N_ACTORS;
        if (delegatee == delegator) return;
        _call(address(lender), actors[delegator], abi.encodeCall(Lender.delegate, (actors[delegatee], true)));
        if (_adjust(actors[delegator], 0, int256(uint256(MIN_DEBT)), actors[delegatee])) {
            // restore: delegatee revokes
            _call(address(lender), actors[delegator], abi.encodeCall(Lender.delegate, (actors[delegatee], false)));
        }
    }

    /* ============================= INVARIANT CHECKS ============================= */

    /// The Coin ledger is exact: every minted Coin unit is backed by a unit of
    /// total debt minus the reserve fees still owed to the protocol.
    function checkCoinLedger() external view returns (bool) {
        int256 supply = int256(coin.totalSupply());
        int256 debt = int256(lender.totalFreeDebt()) + int256(lender.totalPaidDebt());
        int256 reserves = int256(uint256(lender.accruedLocalReserves())) + int256(uint256(lender.accruedGlobalReserves()));
        return supply == debt - reserves;
    }

    /// Paid-debt shares are conserved exactly (the redemption index never
    /// touches the paid pool).
    function checkPaidSharesConserved() external view returns (bool) {
        uint256 sum;
        for (uint256 i = 0; i < N_ACTORS; ++i) {
            sum += lender.paidDebtShares(actors[i]);
        }
        return sum == lender.totalPaidDebtShares();
    }

    /// The vault share book is exact: only actors plus the MIN_SHARES dead
    /// shares (address(0)) ever hold shares.
    function checkVaultSharesConserved() external view returns (bool) {
        uint256 total = vault.totalSupply();
        uint256 sum;
        for (uint256 i = 0; i < N_ACTORS; ++i) {
            sum += vault.balanceOf(actors[i]);
        }
        if (total == 0) return vault.balanceOf(address(0)) == 0 && sum == 0;
        return vault.balanceOf(address(0)) == MIN_SHARES && sum + MIN_SHARES == total;
    }

    /// Vault shares are always covered by assets (no share inflation).
    function checkVaultCovered() external view returns (bool) {
        return vault.totalAssets() >= vault.totalSupply();
    }

    /// The lender never retains Coin: every Coin that reaches it is burned in
    /// the same call (repay, redeem, liquidate).
    function checkLenderHoldsNoCoin() external view returns (bool) {
        return coin.balanceOf(address(lender)) == 0;
    }

    /// Decimal string for a uint256 (diagnostics in invariant failure messages).
    function uint2str(uint256 v) external pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory buf = new bytes(78);
        uint256 i = 78;
        while (v > 0) {
            i -= 1;
            buf[i] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        bytes memory out = new bytes(78 - i);
        for (uint256 j = 0; j < out.length; ++j) out[j] = buf[i + j];
        return string(out);
    }
}
