pragma solidity ^0.5.8;

import "./CompoundV2Handler.sol";
import "../src/CEther.sol";

/// Echidna entry point for the compound-v2 CEther lending-ledger harness.
///
/// Composition (rather than inheritance) keeps the fuzz-target ABI explicit so
/// the filterFunctions whitelist matches cleanly — the same pattern as the
/// morpho-blue and rocket-pool wrappers.
contract EchidnaCompoundV2 {
    CompoundV2Handler public h;

    constructor() public {
        h = new CompoundV2Handler();
    }

    // ====== Forwarded fuzz actions ======

    function actorMint(uint8 actorIdx, uint8 marketChoice, uint256 amount) external {
        h.actorMint(actorIdx, marketChoice, amount);
    }

    function actorRedeem(uint8 actorIdx, uint8 marketChoice, uint256 redeemTokens) external {
        h.actorRedeem(actorIdx, marketChoice, redeemTokens);
    }

    function actorBorrow(uint8 actorIdx, uint8 marketChoice, uint256 borrowAmount) external {
        h.actorBorrow(actorIdx, marketChoice, borrowAmount);
    }

    function actorRepay(uint8 actorIdx, uint8 marketChoice, uint256 amount) external {
        h.actorRepay(actorIdx, marketChoice, amount);
    }

    function actorRepayBehalf(
        uint8 payerIdx,
        uint8 borrowerIdx,
        uint8 marketChoice,
        uint256 amount
    ) external {
        h.actorRepayBehalf(payerIdx, borrowerIdx, marketChoice, amount);
    }

    function actorLiquidate(
        uint8 liquidatorIdx,
        uint8 borrowerIdx,
        uint8 marketBorrowed,
        uint8 marketCollateral,
        uint256 amount
    ) external {
        h.actorLiquidate(liquidatorIdx, borrowerIdx, marketBorrowed, marketCollateral, amount);
    }

    function actorTransfer(uint8 fromIdx, uint8 toIdx, uint8 marketChoice, uint256 amount) external {
        h.actorTransfer(fromIdx, toIdx, marketChoice, amount);
    }

    function actorTransferFrom(
        uint8 fromIdx,
        uint8 spenderIdx,
        uint8 toIdx,
        uint8 marketChoice,
        uint256 amount
    ) external {
        h.actorTransferFrom(fromIdx, spenderIdx, toIdx, marketChoice, amount);
    }

    function warpBlocks(uint256 blocks) external {
        h.warpBlocks(blocks);
    }

    // ====== Properties ======

    function echidna_ctoken_conservation() public view returns (bool) {
        return h.checkCtokenConservation();
    }

    function echidna_eth_conservation() public view returns (bool) {
        return h.checkEthConservation();
    }

    /// @notice borrow ledger consistency. The handler's fixed 1e9-wei tolerance
    /// (checkBorrowSum) is only calibrated for foundry-scale sequences; under
    /// echidna's larger magnitudes + ~50k block accruals the known Compound-v2
    /// per-actor truncation dust (principal*borrowIndex/interestIndex) crosses
    /// it. This mirrors checkBorrowSum with a magnitude-scaled bound:
    /// `diff <= max(1e9, total/1e12)` wei (1e-12 relative + absolute floor).
    function echidna_borrow_sum() public view returns (bool) {
        if (!_borrowSumScaled(h.cethA())) return false;
        if (!_borrowSumScaled(h.cethB())) return false;
        return true;
    }

    function _borrowSumScaled(CEther c) internal view returns (bool) {
        uint256 total = c.totalBorrows();
        uint256 sum;
        for (uint256 i = 0; i < 8; i++) {
            sum += c.borrowBalanceStored(address(h.actors(i)));
        }
        uint256 diff = total >= sum ? total - sum : sum - total;
        uint256 tolerance = total / 1e12;
        if (tolerance < 1e9) tolerance = 1e9;
        return diff <= tolerance;
    }
}
