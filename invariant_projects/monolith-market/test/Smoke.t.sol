// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./MonolithHandler.sol";

/// @notice Deterministic smoke tests over the monolith-market Lender/Vault
/// harness. No forge-std dependency, matching the balancer-v2 / compound-v3
/// playbook. Tests drive the real protocol directly with pranked actors so
/// guard messages, the exact Coin ledger, the redemption index and the ERC4626
/// share book can be pinned precisely.
contract MonolithSmokeTests {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    MonolithHandler internal h;
    Lender internal lender;
    Vault internal vault;
    Coin internal coin;
    MockCollateral internal collateral;
    MockChainlinkFeed internal feed;
    Factory internal factory;

    constructor() {
        h = new MonolithHandler();
        lender = h.lender();
        vault = h.vault();
        coin = h.coin();
        collateral = h.collateral();
        feed = h.feed();
        factory = h.factory();
    }

    function _prank(address who) internal {
        VM.startPrank(who);
    }

    function _unprank() internal {
        VM.stopPrank();
    }

    /// deposit -> borrow -> repay -> withdraw collateral round-trips exactly.
    /// Borrowing power at the honest $1800 price with 75% collateral factor is
    /// 1350 Coin per WSTONE, so 10 WSTONE backs a 1000 Coin loan.
    function test_deposit_borrow_repay_withdraw_roundtrip() public {
        address a = h.actors(0);
        _prank(a);
        lender.adjust(a, 10e18, 0);
        lender.adjust(a, 0, 1000e18);
        _unprank();

        require(coin.balanceOf(a) == 1000e18, "coin not minted to borrower");
        require(lender.getDebtOf(a) == 1000e18, "debt not recorded");
        require(lender._cachedCollateralBalances(a) == 10e18, "collateral not cached");
        require(h.checkCoinLedger(), "ledger broken after borrow");

        _prank(a);
        lender.adjust(a, 0, -1000e18);
        lender.adjust(a, -10e18, 0);
        _unprank();

        require(coin.balanceOf(a) == 0, "coin not burned on repay");
        require(lender.getDebtOf(a) == 0, "debt not zeroed");
        require(lender._cachedCollateralBalances(a) == 0, "collateral not returned");
        require(collateral.balanceOf(a) == h.PREFUND_COLLATERAL(), "collateral not restored");
        require(h.checkCoinLedger(), "ledger broken after repay");
    }

    /// Borrowing more than borrowing power (or repaying below the minimum debt)
    /// reverts, and an unauthorized withdraw of another account's collateral
    /// reverts.
    function test_solvency_and_authorization_guards() public {
        address a = h.actors(0);
        address b = h.actors(1);
        _prank(a);
        lender.adjust(a, 1e18, 0);
        _unprank();

        // 1 WSTONE backs 1350 Coin; borrow 2000 Coin must fail solvency.
        _prank(a);
        VM.expectRevert(bytes("Solvency check failed"));
        lender.adjust(a, 0, 2000e18);
        _unprank();

        // b (no delegation) cannot withdraw a's collateral.
        _prank(b);
        VM.expectRevert(bytes("Unauthorized"));
        lender.adjust(a, -1e18, 0);
        _unprank();

        // Partial repayment must leave the account at 0 debt or >= minDebt.
        _prank(a);
        lender.adjust(a, 0, 100e18);
        _unprank();
        require(lender.getDebtOf(a) == 100e18, "borrow after guards");

        _prank(a);
        VM.expectRevert(bytes("Debt below minimum and larger than 0"));
        lender.adjust(a, 0, -95e18);
        _unprank();

        require(h.checkCoinLedger() && h.checkPaidSharesConserved(), "ledger broken");
    }

    /// An underwater position is liquidated under a 5% oracle shock: 25% of
    /// the debt is repaid with Coin, the liquidator receives collateral at the
    /// shocked price plus incentive, and the honest price is restored.
    function test_liquidation_under_price_shock() public {
        address borrower = h.actors(0);
        address liquidator = h.actors(1);

        _prank(borrower);
        lender.adjust(borrower, 10e18, 0);
        lender.adjust(borrower, 0, 1000e18);
        _unprank();
        _prank(liquidator);
        lender.adjust(liquidator, 10e18, 0);
        lender.adjust(liquidator, 0, 1000e18);
        _unprank();
        require(coin.balanceOf(liquidator) == 1000e18, "liquidator has no Coin");

        uint256 collBefore = lender._cachedCollateralBalances(borrower);
        feed.setPrice(h.PRICE() / 20); // $90 = 5% of honest; BP = 675e18 < 1000e18 debt
        _prank(liquidator);
        uint256 collOut = lender.liquidate(borrower, 1000e18, 0);
        _unprank();
        feed.setPrice(h.PRICE());

        require(lender.getDebtOf(borrower) == 0, "debt not liquidated");
        require(collOut == 10e18, "full collateral not seized at deep shock");
        require(lender._cachedCollateralBalances(borrower) == collBefore - collOut, "collateral book off");
        require(coin.balanceOf(liquidator) == 0, "Coin not burned");
        require(collateral.balanceOf(liquidator) > h.PREFUND_COLLATERAL() - 10e18, "liquidator gained collateral");

        require(h.checkCoinLedger(), "ledger broken after liquidation");
        require(h.checkPaidSharesConserved(), "paid share book broken");
    }

    /// Redemption: a redeemer swaps Coin for collateral against the free debt
    /// pool. The redeemer's Coin is burned and free debt shrinks; the free
    /// debtor's collateral balance is debited lazily on its next touch.
    function test_redeem_against_free_debt() public {
        address debtor = h.actors(0);
        address redeemer = h.actors(1);

        _prank(debtor);
        lender.setRedemptionStatus(debtor, true);
        lender.adjust(debtor, 10e18, 0);
        lender.adjust(debtor, 0, 1000e18);
        _unprank();
        require(lender.isRedeemable(debtor), "not opted in");
        require(lender.totalFreeDebt() == 1000e18, "free debt not recorded");

        _prank(redeemer);
        lender.adjust(redeemer, 10e18, 0);
        lender.adjust(redeemer, 0, 1000e18);
        _unprank();

        uint256 out = lender.getRedeemAmountOut(500e18);
        require(out > 0, "nothing redeemable");
        _prank(redeemer);
        uint256 collateralOut = lender.redeem(500e18, 0);
        _unprank();

        require(collateralOut == out, "redeem amount mismatch");
        require(lender.totalFreeDebt() == 500e18, "free debt not reduced");
        require(coin.balanceOf(redeemer) == 500e18, "Coin not burned");
        require(collateral.balanceOf(redeemer) == h.PREFUND_COLLATERAL() - 10e18 + collateralOut, "collateral not paid");

        // The debtor's cached collateral is only debited on the next touch.
        require(lender._cachedCollateralBalances(debtor) == 10e18, "collateral debited eagerly");
        _prank(debtor);
        lender.adjust(debtor, 0, -500e18);
        _unprank();
        require(lender._cachedCollateralBalances(debtor) < 10e18, "collateral not debited lazily");

        require(h.checkCoinLedger(), "ledger broken after redeem");
        require(h.checkPaidSharesConserved(), "paid share book broken");
    }

    /// Vault: deposit -> withdraw round-trips the ERC4626 share book exactly,
    /// including the MIN_SHARES dead shares burned to address(0) against the
    /// inflation attack. The dead share equivalent of assets is permanently
    /// sequestered, so maxWithdraw(actor) is the full share balance.
    function test_vault_deposit_withdraw_roundtrip() public {
        address a = h.actors(2);
        _prank(a);
        lender.adjust(a, 10e18, 0);
        lender.adjust(a, 0, 200e18);
        _unprank();
        require(coin.balanceOf(a) == 200e18, "no Coin to stake");

        _prank(a);
        uint256 shares = vault.deposit(100e18, a);
        _unprank();

        require(shares == 100e18 - h.MIN_SHARES(), "dead shares not deducted");
        require(vault.balanceOf(address(0)) == h.MIN_SHARES(), "dead shares missing");
        require(vault.totalSupply() == 100e18, "totalSupply includes dead shares");
        require(h.checkVaultSharesConserved(), "vault share book broken");

        uint256 maxW = vault.maxWithdraw(a);
        require(maxW == 100e18 - h.MIN_SHARES(), "maxWithdraw excludes dead share assets");
        _prank(a);
        uint256 back = vault.withdraw(maxW, a, a);
        _unprank();

        require(back == shares, "shares not restored on withdraw");
        require(vault.balanceOf(a) == 0, "vault balance not zeroed");
        require(coin.balanceOf(a) == 200e18 - h.MIN_SHARES(), "assets not returned minus dead");
        require(vault.balanceOf(address(0)) == h.MIN_SHARES(), "dead shares moved");
        require(vault.totalAssets() == h.MIN_SHARES(), "dead share assets must stay locked");
        require(h.checkVaultSharesConserved() && h.checkVaultCovered(), "vault book broken");
        require(h.checkCoinLedger(), "ledger broken");
    }

    /// Interest accrues on paid debt and is split between stakers (vault) and
    /// the global reserve fee (1% factory fee). The Coin ledger identity
    /// supply == debt - reserves holds exactly after accrual.
    function test_interest_accrual_and_reserve_pull() public {
        address a = h.actors(0);
        address staker = h.actors(2);
        address feeRecipient = h.actors(1);

        _prank(a);
        lender.adjust(a, 10e18, 0);
        lender.adjust(a, 0, 1000e18);
        _unprank();
        _prank(staker);
        lender.adjust(staker, 10e18, 0);
        lender.adjust(staker, 0, 1000e18);
        vault.deposit(500e18, staker);
        _unprank();

        require(lender.accruedGlobalReserves() == 0, "reserves before accrual");

        h.warp(30 days);

        // A zero-delta adjust forces accrueInterest after the warp.
        _prank(a);
        lender.adjust(a, 0, 0);
        _unprank();

        require(lender.totalPaidDebt() > 2000e18, "no interest accrued");
        require(vault.totalAssets() > 500e18, "stakers earned nothing");
        require(lender.accruedGlobalReserves() > 0, "global reserve fee not accrued");
        require(h.checkCoinLedger(), "ledger broken after accrual");

        // Operator pulls local reserves — the local fee remainder lands on the
        // operator and the ledger stays balanced.
        h.pullLocalReserves(1);
        require(h.checkCoinLedger(), "ledger broken after local pull");

        // Fee recipient pulls the global reserve through the factory (the
        // factory mints the fee to them).
        h.pullGlobalReserves(1);

        require(coin.balanceOf(feeRecipient) > 0, "global reserves not pulled");
        require(lender.accruedGlobalReserves() == 0, "global reserves not cleared");
        require(h.checkCoinLedger(), "ledger broken after global pull");
    }

    /// Factory and protocol guards: fee cap, operator gating, fee-recipient
    /// gating of reserve pulls, and lender setter gating.
    function test_guards() public {
        address stranger = h.actors(5);

        // Factory operator (0x2000) can set a 10% fee; beyond the cap reverts.
        _prank(h.FACTORY_OPERATOR());
        VM.expectRevert(bytes("Feebps must be less than or equal to 1000"));
        factory.setFeeBps(1001);
        _unprank();

        // A non-operator cannot set factory fees.
        _prank(stranger);
        VM.expectRevert(bytes("Only operator can call this function"));
        factory.setFeeBps(100);
        _unprank();

        // Only the fee recipient can pull reserves through the factory.
        _prank(stranger);
        VM.expectRevert(bytes("Only fee recipient can pull reserves"));
        factory.pullReserves(address(lender));
        _unprank();

        // Lender setters are operator-gated (the Lender's onlyOperator error).
        _prank(stranger);
        VM.expectRevert(bytes("Unauthorized"));
        lender.setRedeemFeeBps(50);
        _unprank();

        // A delegatee can adjust a delegator's position only after delegation.
        address delegatee = h.actors(3);
        address delegator = h.actors(0);
        _prank(delegatee);
        VM.expectRevert(bytes("Unauthorized"));
        lender.adjust(delegator, 0, 10e18);
        _unprank();

        _prank(delegator);
        lender.adjust(delegator, 1e18, 0); // give the delegator backing collateral
        lender.delegate(delegatee, true);
        _unprank();
        _prank(delegatee);
        lender.adjust(delegator, 0, 100e18);
        _unprank();
        require(lender.getDebtOf(delegator) == 100e18, "delegated borrow failed");
        require(h.checkCoinLedger(), "ledger broken");
    }

    /// CONFIRMED PROTOCOL BUG: writeOff deletes the last remaining debtor's
    /// debt without burning the matching Coin. After a 99.9%+ price collapse
    /// (or the tail of the oracle staleness unwind window, where liquidations
    /// stay enabled at an unwound price), anyone can call writeOff on the sole
    /// borrower: the debt is removed, totalFreeDebt + totalPaidDebt falls to
    /// zero, no other debtor absorbs it (the redistribution branch is skipped),
    /// and the outstanding Coin is permanently unbacked. The Coin ledger
    /// identity supply == totalDebt - reserves breaks exactly here.
    function test_writeoff_last_debtor_breaks_coin_backing() public {
        address borrower = h.actors(0);
        address caller = h.actors(1);

        _prank(borrower);
        lender.adjust(borrower, 10e18, 0);
        lender.adjust(borrower, 0, 1000e18);
        _unprank();
        require(coin.totalSupply() == 1000e18, "Coin minted");
        require(lender.totalPaidDebt() == 1000e18, "debt booked");
        require(h.checkCoinLedger(), "ledger clean before writeOff");

        // Collateral collapses to $0.50 (0.028% of honest): collateral value
        // 5e18, so debt (1e21) is 200x the collateral value -> writeOff fires
        // while liquidations are still enabled (fresh, positive price).
        feed.setPrice(5e7);

        _prank(caller);
        bool writtenOff = lender.writeOff(borrower, caller);
        _unprank();

        require(writtenOff, "writeOff should trigger");
        require(lender.getDebtOf(borrower) == 0, "debt not removed");
        require(lender._cachedCollateralBalances(borrower) == 0, "collateral not seized");
        require(collateral.balanceOf(caller) > h.PREFUND_COLLATERAL(), "collateral not paid to caller");

        // BUG: Coin supply unchanged and total debt zero -> unbacked Coin.
        require(coin.totalSupply() == 1000e18, "Coin should have been burned");
        require(lender.totalPaidDebt() == 0 && lender.totalFreeDebt() == 0, "debt vanished");
        require(!h.checkCoinLedger(), "Coin ledger must break");
    }
}
