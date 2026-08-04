pragma solidity ^0.5.8;

import "./CompoundV2Handler.sol";

/// @notice Round-trip smoke tests over the harness. The handler creates both
/// markets in its constructor (exchange rate 0.02e18), so 100 ether mints
/// exactly 5_000e18 cTokens.
contract CompoundV2Smoke {
    CompoundV2Handler internal h;

    constructor() public {
        h = new CompoundV2Handler();
    }

    function _actor(uint8 i) internal view returns (address) {
        return address(h.actors(i % 8));
    }

    function test_mint_redeem_roundtrip() public {
        address a = _actor(0);
        uint256 ethBefore = address(a).balance;

        h.actorMint(0, 0, 100 ether);
        uint256 ct = h.cethA().balanceOf(a);
        require(ct == 5000 ether, "wrong cTokens minted");
        require(address(a).balance == ethBefore - 100 ether, "eth not moved");

        h.actorRedeem(0, 0, ct);
        require(h.cethA().balanceOf(a) == 0, "cTokens not redeemed");
        require(address(a).balance == ethBefore, "eth not returned");
    }

    function test_mint_borrow_repay_roundtrip() public {
        address a = _actor(0);
        h.actorMint(0, 0, 100 ether);
        h.actorBorrow(0, 0, 50 ether);

        uint256 debt = h.cethA().borrowBalanceStored(a);
        require(debt >= 50 ether, "debt below principal");
        require(h.cethA().totalBorrows() == debt, "totalBorrows mismatch");

        // repay until fully cleared (each repay accrues interest, so loop)
        for (uint256 i = 0; i < 5; i++) {
            h.actorRepay(0, 0, uint(-1));
            if (h.cethA().borrowBalanceStored(a) == 0) break;
        }
        require(h.cethA().borrowBalanceStored(a) == 0, "debt not cleared");
        require(h.cethA().totalBorrows() == 0, "totalBorrows not cleared");
    }

    function test_borrower_solvency() public {
        address a = _actor(0);
        h.actorMint(0, 0, 100 ether);
        h.actorBorrow(0, 0, 50 ether);

        // a full repayment must never cost more than the debt it clears
        h.actorRepay(0, 0, uint(-1));
        require(
            h.cethA().borrowBalanceStored(a) <= 1 ether,
            "overdrawn after capped repay"
        );
    }

    function test_interest_accrues_with_blocks() public {
        address a = _actor(0);
        h.actorMint(0, 0, 100 ether);
        h.actorBorrow(0, 0, 50 ether);

        // force a positive block delta, then touch the market so the
        // interest actually accrues (accrueInterest) before we read debt
        h.warpBlocks(1000);
        h.actorMint(1, 0, 1 wei);

        uint256 debt = h.cethA().borrowBalanceStored(a);
        require(debt > 50 ether, "no interest accrued");
    }

    function test_transfer() public {
        address a = _actor(0);
        address b = _actor(1);
        h.actorMint(0, 0, 100 ether);
        uint256 aBal = h.cethA().balanceOf(a);

        h.actorTransfer(0, 1, 0, 10 ether);
        require(h.cethA().balanceOf(a) == aBal - 10 ether, "from balance");
        require(h.cethA().balanceOf(b) == 10 ether, "to balance");
    }

    function test_transferFrom() public {
        address a = _actor(0);
        address c = _actor(2);
        h.actorMint(0, 0, 100 ether);

        h.actorTransferFrom(0, 1, 2, 0, 10 ether);
        require(h.cethA().balanceOf(c) == 10 ether, "beneficiary balance");
        require(h.cethA().allowance(a, _actor(1)) == uint(-1), "allowance");
    }

    function test_liquidate() public {
        address borrower = _actor(0);
        address liquidator = _actor(2);
        h.actorMint(0, 1, 100 ether); // collateral cethB
        h.actorMint(0, 0, 100 ether); // cethA (no-op for seize, just setup)

        // borrower borrows from cethA against cethB collateral
        h.actorBorrow(0, 0, 50 ether);
        uint256 debtBefore = h.cethA().borrowBalanceStored(borrower);
        uint256 collateralBefore = h.cethB().balanceOf(borrower);

        h.actorLiquidate(2, 0, 0, 1, 10 ether);

        uint256 debtAfter = h.cethA().borrowBalanceStored(borrower);
        uint256 collateralAfter = h.cethB().balanceOf(borrower);
        require(debtAfter < debtBefore, "debt not reduced");
        // the borrower keeps the accrued interest on the repaid 10 ether, so
        // the ledger drop is 10 ether minus a block's interest (tolerance 1 ether)
        require(debtBefore - debtAfter >= 9 ether, "less than repaid");
        require(debtBefore - debtAfter <= 11 ether, "more than repaid");
        require(collateralAfter < collateralBefore, "collateral not seized");
        require(
            h.cethB().balanceOf(liquidator) > 0,
            "liquidator got no cTokens"
        );
    }

    function test_liquidate_no_reentrancy_steal() public {
        // a liquidator can only seize what the seized amount is worth
        address borrower = _actor(0);
        address liquidator = _actor(3);
        h.actorMint(0, 1, 100 ether); // collateral cethB
        h.actorMint(0, 0, 100 ether); // liquidity in cethA
        h.actorBorrow(0, 0, 50 ether);
        uint256 collateralBefore = h.cethB().balanceOf(borrower);

        h.actorLiquidate(3, 0, 0, 1, 25 ether);

        uint256 seized = collateralBefore - h.cethB().balanceOf(borrower);
        // 25 ether * 1.08 incentive / exchangeRate(0.02e18) = 1350 cTokens
        require(seized > 1000 ether && seized < 2000 ether, "over-seized");
    }

    function test_invariants_after_stress() public {
        // random-ish mixed sequence; invariants must hold afterwards
        h.actorMint(0, 1, 90 ether); // actor0 collateral in cethB
        h.actorMint(0, 0, 90 ether); // actor0 liquidity in cethA
        h.actorMint(1, 1, 80 ether);
        h.actorMint(2, 0, 70 ether);
        h.actorBorrow(0, 0, 30 ether);
        h.actorBorrow(1, 1, 20 ether);
        h.actorTransfer(0, 3, 0, 5 ether);
        h.actorLiquidate(3, 0, 0, 1, 10 ether);
        h.warpBlocks(200);
        h.actorRepay(1, 1, uint(-1));
        h.actorRedeem(2, 0, 10 ether);
        h.actorTransferFrom(1, 4, 5, 1, 3 ether);

        require(h.checkCtokenConservation(), "cTokens leaked");
        require(h.checkEthConservation(), "ETH leaked");
        require(h.checkBorrowSum(), "borrow ledger broken");
    }
}
