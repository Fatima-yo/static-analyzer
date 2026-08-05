// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./MorphoHandler.sol";

/// @notice Deterministic smoke tests over the morpho-blue harness. No forge-std
/// dependency, matching the balancer-v2 / rocket-pool playbook. Tests 1-2 route
/// through the handler (exercising the harness entry points); tests 3-8 drive
/// the real Morpho contract directly with pranked actors so guard messages and
/// liquidation/bad-debt accounting can be pinned exactly.
contract MorphoSmokeTests {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    MorphoHandler internal h;

    constructor() {
        h = new MorphoHandler();
    }

    /// supply -> withdraw round-trips exactly (virtual shares make the
    /// first-deposit conversion lossless).
    function test_supply_withdraw_roundtrip() public {
        h.supply(0, 1000e6);
        uint256 shares = _supplyShares(0, h.actors(0));
        h.withdraw(0, shares);

        require(h.usdc().balanceOf(h.actors(0)) == h.PREFUND_USDC(), "USDC not restored");
        require(_supplyShares(0, h.actors(0)) == 0, "shares not zeroed");
        require(h.checkTokenBalance(0), "USDC identity broken");
        require(h.checkSupplySharesConserved(0), "supply shares broken");
        require(h.checkMarketSolvent(0), "market A insolvent");
    }

    /// supplyCollateral -> borrow -> repay -> withdrawCollateral round-trips
    /// with only the accrued interest lost.
    function test_supply_collateral_borrow_repay_roundtrip() public {
        h.supply(3, 10000e6);
        h.supplyCollateral(0, 10 ether);
        h.borrow(0, 8600e6);

        (uint256 sShares, uint128 bShares, uint128 coll) = h.morpho().position(h.ids(0), h.actors(0));
        sShares; coll;
        require(bShares > 0, "no borrow position");

        h.repay(0, bShares);
        h.withdrawCollateral(0, 10 ether);

        (uint256 sShares2, uint128 bShares2, uint128 coll2) = h.morpho().position(h.ids(0), h.actors(0));
        require(sShares2 == 0 && bShares2 == 0 && coll2 == 0, "position not fully closed");
        require(h.usdc().balanceOf(h.actors(0)) >= h.PREFUND_USDC() - 8600e6 - 100e6, "borrow interest wrong");
        require(h.checkTokenBalance(0) && h.checkTokenBalance(1), "balance identity broken");
        require(h.checkBorrowSharesConserved(0) && h.checkMarketSolvent(0), "ledger broken");
    }

    /// An unhealthy position (oracle shock) is liquidatable and the ledger
    /// conservation holds through the liquidation.
    function test_liquidate_unhealthy_position() public {
        Morpho m = h.morpho();
        MarketParams memory mp0 = h.mp(0);
        address borrower = h.actors(0);
        address liquidator = h.actors(1);

        h.supply(2, 20000e6);

        VM.startPrank(borrower);
        m.supplyCollateral(mp0, 10 ether, borrower, "");
        m.borrow(mp0, 15000e6, 0, borrower, borrower);
        VM.stopPrank();

        (, uint128 bSharesBefore, ) = m.position(h.ids(0), borrower);
        require(bSharesBefore > 0, "no debt");

        h.oracleA().setPrice(h.ORACLE_A_BASE() / 2);
        uint256 halfShares = bSharesBefore / 2;
        uint256 liqWethBefore = h.weth().balanceOf(liquidator);
        VM.startPrank(liquidator);
        m.liquidate(mp0, borrower, 0, halfShares, "");
        VM.stopPrank();
        h.oracleA().setPrice(h.ORACLE_A_BASE());

        (, uint128 bSharesAfter, ) = m.position(h.ids(0), borrower);
        uint256 liqWethAfter = h.weth().balanceOf(liquidator);
        require(bSharesAfter == bSharesBefore - halfShares, "wrong shares repaid");
        require(liqWethAfter > liqWethBefore, "liquidator got no collateral");
        require(h.checkSupplySharesConserved(0) && h.checkBorrowSharesConserved(0), "share ledger broken");
        require(h.checkTokenBalance(0) && h.checkTokenBalance(1), "balance identity broken");
        require(h.checkMarketSolvent(0), "market A insolvent");
    }

    /// Deep-underwater liquidation seizes all collateral and writes off the
    /// bad debt while keeping the market solvent and the balance-sheet exact.
    function test_bad_debt_writeoff_keeps_ledger_solvent() public {
        Morpho m = h.morpho();
        MarketParams memory mp0 = h.mp(0);
        address borrower = h.actors(0);
        address liquidator = h.actors(1);

        h.supply(2, 5000e6);

        VM.startPrank(borrower);
        m.supplyCollateral(mp0, 1 ether, borrower, "");
        m.borrow(mp0, 1700e6, 0, borrower, borrower);
        VM.stopPrank();

        (uint128 saBefore, , uint128 baBefore, , , ) = m.market(h.ids(0));
        saBefore; baBefore;

        h.oracleA().setPrice(h.ORACLE_A_BASE() / 100);
        VM.startPrank(liquidator);
        m.liquidate(mp0, borrower, 1 ether, 0, "");
        VM.stopPrank();
        h.oracleA().setPrice(h.ORACLE_A_BASE());

        (, uint128 bSharesAfter, uint128 collAfter) = m.position(h.ids(0), borrower);
        require(collAfter == 0, "collateral not fully seized");
        require(bSharesAfter == 0, "bad debt not written off");

        (uint128 saAfter, , uint128 baAfter, , , ) = m.market(h.ids(0));
        require(uint256(saAfter) >= uint256(baAfter), "market insolvent after bad debt");
        require(h.checkSupplySharesConserved(0) && h.checkBorrowSharesConserved(0), "share ledger broken");
        require(h.checkTokenBalance(0) && h.checkTokenBalance(1), "balance identity broken");
        require(h.checkMarketSolvent(0) && h.checkMarketSolvent(1), "market insolvent");
    }

    /// Interest accrual mints fee shares to the fee recipient while keeping the
    /// supply-share ledger and the balance sheet exact.
    function test_fee_accrual_credits_recipient() public {
        address supplier = h.actors(2);
        address borrower = h.actors(3);

        VM.startPrank(supplier);
        h.morpho().supply(h.mp(0), 10000e6, 0, supplier, "");
        VM.stopPrank();
        VM.startPrank(borrower);
        h.morpho().supplyCollateral(h.mp(0), 10 ether, borrower, "");
        h.morpho().borrow(h.mp(0), 8000e6, 0, borrower, borrower);
        VM.stopPrank();

        (uint256 fBefore, , ) = h.morpho().position(h.ids(0), h.FEE_RECIPIENT());

        VM.warp(block.timestamp + 30 days);
        h.morpho().accrueInterest(h.mp(0));

        (uint256 fAfter, , ) = h.morpho().position(h.ids(0), h.FEE_RECIPIENT());
        require(fAfter > fBefore, "fee recipient got no shares");
        require(h.checkSupplySharesConserved(0), "supply shares broken after accrual");
        require(h.checkTokenBalance(0), "USDC identity broken after accrual");
        require(h.checkMarketSolvent(0), "market A insolvent after accrual");
    }

    /// Withdrawing / borrowing beyond the idle liquidity reverts with the
    /// documented INSUFFICIENT_LIQUIDITY guard.
    function test_insufficient_liquidity_reverts() public {
        Morpho m = h.morpho();
        MarketParams memory mp0 = h.mp(0);
        address supplier = h.actors(4);
        address borrower = h.actors(5);

        VM.startPrank(supplier);
        m.supply(mp0, 1000e6, 0, supplier, "");
        VM.stopPrank();
        VM.startPrank(borrower);
        m.supplyCollateral(mp0, 10 ether, borrower, "");
        m.borrow(mp0, 800e6, 0, borrower, borrower);
        VM.stopPrank();

        VM.startPrank(supplier);
        VM.expectRevert("insufficient liquidity");
        m.withdraw(mp0, 500e6, 0, supplier, supplier);
        VM.stopPrank();

        VM.startPrank(borrower);
        VM.expectRevert("insufficient liquidity");
        m.borrow(mp0, 500e6, 0, borrower, borrower);
        VM.stopPrank();

        require(h.checkMarketSolvent(0), "market A insolvent");
    }

    /// Zero-address guards on every entry point, the onlyOwner guards, and the
    /// *documented* owner behavior that setOwner/setFeeRecipient accept the
    /// zero address (the two run3 ZeroAddress findings).
    function test_zero_address_and_owner_guards() public {
        Morpho m = h.morpho();
        MarketParams memory mp0 = h.mp(0);
        address actor = h.actors(6);

        VM.startPrank(actor);
        VM.expectRevert("zero address");
        m.supply(mp0, 1e6, 0, address(0), "");
        VM.expectRevert("zero address");
        m.supplyCollateral(mp0, 1e6, address(0), "");
        VM.expectRevert("zero address");
        m.withdraw(mp0, 1, 0, actor, address(0));
        VM.expectRevert("zero address");
        m.borrow(mp0, 1, 0, actor, address(0));
        VM.expectRevert("zero address");
        m.repay(mp0, 1, 0, address(0), "");
        VM.expectRevert("zero address");
        m.withdrawCollateral(mp0, 1, actor, address(0));

        VM.expectRevert("not owner");
        m.enableIrm(address(0xDEAD));
        VM.expectRevert("not owner");
        m.enableLltv(0.9e18);
        VM.expectRevert("not owner");
        m.setFee(mp0, 0.05e18);
        VM.expectRevert("not owner");
        m.setFeeRecipient(actor);
        VM.expectRevert("not owner");
        m.setOwner(address(0));
        VM.stopPrank();

        // Documented design: the owner MAY set the owner and fee recipient to
        // the zero address (interface NatSpec explicitly warns about it) — but
        // note this is a one-way door: once owner == 0 nobody can recover it.
        VM.startPrank(h.OWNER());
        m.setFeeRecipient(address(0));
        m.setOwner(address(0));
        VM.stopPrank();
        require(m.owner() == address(0), "setOwner(0) failed");
        require(m.feeRecipient() == address(0), "setFeeRecipient(0) failed");
    }

    /// Deposit then immediate withdraw in the same block (no interest accrual)
    /// returns exactly the deposited assets: rounding can never mint free value.
    function test_roundtrip_no_free_value() public {
        address actor = h.actors(7);

        VM.startPrank(actor);
        h.morpho().supply(h.mp(0), 1000e6, 0, actor, "");
        uint256 shares = _supplyShares(0, actor);
        h.morpho().withdraw(h.mp(0), 0, shares, actor, actor);
        VM.stopPrank();

        require(h.usdc().balanceOf(actor) == h.PREFUND_USDC(), "roundtrip not lossless");
        require(h.checkSupplySharesConserved(0), "supply shares broken");
        require(h.checkTokenBalance(0), "USDC identity broken");
    }

    function _supplyShares(uint256 m, address who) internal view returns (uint256) {
        (uint256 s, , ) = h.morpho().position(h.ids(m), who);
        return s;
    }
}
