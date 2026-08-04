pragma solidity ^0.5.8;

/// @notice White-Paper style borrow rate model for the invariant harness.
/// baseRatePerBlock 5e12 (≈10.5% APR), multiplier 4.95e14 so the rate is
/// always <= CToken.borrowRateMaxMantissa (5e14/block) at any utilization,
/// keeping `accrueInterest` from ever reverting "borrow rate is absurdly high".
contract SimpleInterestRateModel {
    uint internal constant baseRatePerBlock = 5e12;
    uint internal constant multiplierPerBlock = 4.95e14;

    function getBorrowRate(
        uint cash,
        uint borrows,
        uint reserves
    ) external pure returns (uint, uint) {
        uint borrowRate;
        if (borrows == 0) {
            borrowRate = baseRatePerBlock;
        } else {
            uint total = cash + borrows - reserves;
            if (total == 0) {
                borrowRate = baseRatePerBlock;
            } else {
                uint utilization = (borrows * 1e18) / total;
                borrowRate =
                    baseRatePerBlock +
                    (multiplierPerBlock * utilization) / 1e18;
            }
        }
        return (0, borrowRate);
    }

    function isInterestRateModel() external pure returns (bool) {
        return true;
    }
}
