// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./CreditGuildHandler.sol";

/// @notice deterministic round-trip tests over the handler's action surface.
/// These mirror the fuzzer's reachable states but run step-by-step so a
/// failure pinpoints the exact protocol transition.
contract CreditGuildSmoke {
    CreditGuildHandler internal h;

    constructor() {
        h = new CreditGuildHandler();
    }

    function _actor(uint8 i) internal view returns (address) {
        return h.actors(i);
    }

    function test_borrow_repay_roundtrip() public {
        address a = _actor(0);
        uint256 creditBefore = h.credit().balanceOf(a);
        uint256 collBefore = h.collateral().balanceOf(a);

        h.actorBorrow(0, 0, 0, 0);

        require(h.loanIds(0) != bytes32(0), "no loan id");
        bytes32 id = h.loanIds(0);
        LendingTerm.Loan memory loan = h.term0().getLoan(id);
        require(loan.borrower == a, "wrong borrower");
        require(loan.collateralAmount > 0, "no collateral");
        require(loan.borrowAmount > 0, "no credit");
        require(h.credit().balanceOf(a) > creditBefore, "credit not minted");
        require(h.collateral().balanceOf(a) < collBefore, "collateral not moved");
        require(h.term0().issuance() == loan.borrowAmount, "issuance mismatch");

        h.actorRepay(0, 0);

        loan = h.term0().getLoan(id);
        require(loan.closeTime != 0, "loan not closed");
        require(h.term0().issuance() == 0, "issuance not cleared");
        require(
            h.collateral().balanceOf(a) == collBefore,
            "collateral not returned"
        );
    }

    function test_borrow_partial_then_repay() public {
        // seed 1e21 => borrow 1100e18, above ProfitManager.minBorrow()=100e18,
        // so a partial repay leaves the loan above the min-borrow threshold.
        h.actorBorrow(1, 1, 1e21, 0);
        bytes32 id = h.loanIds(0);
        LendingTerm.Loan memory loan = h.term1().getLoan(id);
        uint256 creditAmount = loan.borrowAmount;
        require(creditAmount > 0, "no loan");

        h.actorPartialRepay(1, 0, creditAmount / 10);
        loan = h.term1().getLoan(id);
        require(loan.closeTime == 0, "partial repaid closed loan");
        require(loan.borrowAmount < creditAmount, "partial repay no-op");
        require(h.term1().issuance() == loan.borrowAmount, "issuance after partial");

        h.actorRepay(1, 0);
        loan = h.term1().getLoan(id);
        require(loan.closeTime != 0, "not closed after repay");
        require(h.term1().issuance() == 0, "issuance not cleared");
    }

    function test_borrow_call_auction_bid() public {
        h.actorBorrow(2, 0, 0, 0);
        bytes32 id = h.loanIds(0);
        LendingTerm.Loan memory loan = h.term0().getLoan(id);
        uint256 coll = loan.collateralAmount;
        require(coll > 0, "no collateral");

        // let the loan go to call; interest makes it underwater quickly
        // (warpDays caps at 30 days per call, so loop to ~210 days)
        for (uint256 i = 0; i < 7; i++) {
            h.warpDays(30);
        }
        h.actorCall(2, 0);

        loan = h.term0().getLoan(id);
        // call() sets callTime; the loan stays open until the auction resolves
        require(loan.callTime != 0, "loan not called");
        require(loan.closeTime == 0, "loan closed before auction");
        require(h.auctionHouse().getAuction(id).startTime != 0, "no auction");

        h.actorBid(3, 0);
        uint256 bidCredit = h.term0().getLoan(id).callDebt;
        require(bidCredit > 0, "no bid credit recorded");
        require(h.credit().balanceOf(_actor(3)) < 100_000 ether, "bidder not debited");
        // collateral went to the winning bidder
        uint256 bidderColl = h.collateral().balanceOf(_actor(3));
        require(
            bidderColl > 1_000_000 ether - coll,
            "bidder did not receive collateral"
        );
    }

    function test_borrow_call_forgive() public {
        h.actorBorrow(4, 1, 0, 0);
        bytes32 id = h.loanIds(0);
        LendingTerm.Loan memory loan = h.term1().getLoan(id);
        uint256 coll = loan.collateralAmount;
        require(coll > 0, "no collateral");

        for (uint256 i = 0; i < 7; i++) {
            h.warpDays(30);
        }
        h.actorCall(4, 0);
        // auction must fully elapse before forgive (creditAsked drops to 0)
        h.warpDays(1);

        h.actorForgive(4, 0);
        loan = h.term1().getLoan(id);
        require(loan.closeTime != 0, "loan not forgiven");
        // collateral stays stuck on the term (recorded by the handler)
        require(h.stuckCollateral() >= coll, "stuck collateral not recorded");
        require(h.term1().issuance() == 0, "forgiven issuance not cleared");
    }

    function test_gauge_increment_decrement() public {
        address a = _actor(0);
        uint256 before = h.guild().getUserGaugeWeight(a, address(h.term0()));
        h.actorIncrementGauge(0, 0, 5_000 ether);
        h.actorIncrementGauge(0, 0, 5_000 ether);
        h.actorIncrementGauge(0, 0, 5_000 ether);
        require(
            h.guild().getUserGaugeWeight(a, address(h.term0())) == before + 15_000 ether,
            "increment mismatch"
        );
        h.actorDecrementGauge(0, 0, 7_000 ether);
        require(
            h.guild().getUserGaugeWeight(a, address(h.term0())) == before + 8_000 ether,
            "decrement mismatch"
        );
    }

    function test_transfers() public {
        address a0 = _actor(0);
        address a1 = _actor(1);
        uint256 g0 = h.guild().balanceOf(a0);
        uint256 g1 = h.guild().balanceOf(a1);
        h.actorTransferGuild(0, 1, 1_000 ether);
        require(h.guild().balanceOf(a0) == g0 - 1_000 ether, "guild send");
        require(h.guild().balanceOf(a1) == g1 + 1_000 ether, "guild receive");

        uint256 c0 = h.credit().balanceOf(a0);
        uint256 c1 = h.credit().balanceOf(a1);
        h.actorTransferCredit(0, 1, 2_000 ether);
        require(h.credit().balanceOf(a0) == c0 - 2_000 ether, "credit send");
        require(h.credit().balanceOf(a1) == c1 + 2_000 ether, "credit receive");
    }

    function test_surplus_donate_and_claim() public {
        address a = _actor(0);
        uint256 creditBal = h.credit().balanceOf(a);
        uint256 bufferBefore = h.profitManager().surplusBuffer();
        h.actorDonateSurplus(0, 1_000 ether);
        require(h.credit().balanceOf(a) == creditBal - 1_000 ether, "donation not taken");
        require(
            h.profitManager().surplusBuffer() == bufferBefore + 1_000 ether,
            "surplus buffer not credited"
        );
        // claimRewards is callable without reverting; the surplus buffer is a
        // loss-absorber (drawn down by notifyPnL), it is not paid out to the
        // donor on claim.
        h.actorClaimRewards(0);
        require(
            h.credit().balanceOf(a) == creditBal - 1_000 ether,
            "claim moved balance unexpectedly"
        );
    }

    function test_rebase_enter_exit() public {
        address a = _actor(1);
        uint256 bal = h.credit().balanceOf(a);
        h.actorEnterRebase(1);
        require(h.credit().isRebasing(a), "not rebasing");
        h.actorExitRebase(1);
        require(!h.credit().isRebasing(a), "still rebasing");
        require(h.credit().balanceOf(a) == bal, "rebase cycle changed balance");
    }

    function test_all_invariants_hold_after_scenario() public {
        // build a messy state: mixed loans (seeds > 100e18 so partial repay
        // stays above minBorrow), a real partial repay, gauge movement,
        // transfers, donation, a called+auctioned loan, a called+forgiven
        // loan, and a full repay. gaugeWeightTolerance is 200% in the handler,
        // so these borrows are below the relative debt ceiling.
        h.actorBorrow(0, 0, 1e21, 0); // term0 loan 1100e18
        h.actorBorrow(1, 1, 1e21, 0); // term1 loan 1100e18
        h.actorBorrow(2, 0, 2e21, 0); // term0 loan 2100e18
        h.actorPartialRepay(0, 0, 100 ether);
        h.actorIncrementGauge(3, 0, 3_000 ether);
        h.actorTransferCredit(3, 4, 4_000 ether);
        h.actorTransferGuild(3, 4, 2_000 ether);
        h.actorDonateSurplus(4, 1_000 ether);

        // 210 days of interest makes every loan underwater -> callable
        for (uint256 i = 0; i < 7; i++) {
            h.warpDays(30);
        }
        h.actorCall(1, 1); // call term1 loan
        h.actorBid(2, 1); // auction it

        h.actorCall(5, 2); // call term0 loan
        h.warpDays(1); // let auction fully elapse
        h.actorForgive(5, 2); // forgive it

        h.actorRepay(0, 0); // full repay of the partial-repaid term0 loan
        h.actorApplyLoss(3, 0); // apply term0 loss before moving gauge weight
        h.actorDecrementGauge(3, 0, 1_000 ether);
        h.actorClaimRewards(0);
        h.actorExitRebase(0);

        require(h.checkCreditConservation(), "credit not conserved");
        require(h.checkGuildConservation(), "guild not conserved");
        require(h.checkGaugeWeightConservation(), "gauge weight not conserved");
        require(h.checkVotesConservation(), "votes not conserved");
        require(h.checkCollateralConservation(), "collateral not conserved");
        require(h.checkIssuanceConsistency(), "issuance inconsistent");
        require(h.checkIssuanceWithinCaps(), "issuance over cap");
    }
}
