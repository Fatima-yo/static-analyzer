pragma solidity ^0.5.8;

import "./CEther.sol";

/// @notice Minimal Compound v2 comptroller for the invariant harness.
/// Every policy hook is permissive (returns NO_ERROR=0) so the fuzzer can
/// reach all accounting transitions (mint/redeem/borrow/repay/liquidate/
/// seize/transfer) including undercollateralized states, where accounting
/// bugs would surface. The liquidation seize math is faithful to the real
/// comptroller with both asset prices pinned to 1e18 and an 8% incentive.
contract SimpleComptroller {
    uint public constant liquidationIncentiveMantissa = 1.08e18;

    function isComptroller() external pure returns (bool) {
        return true;
    }

    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata) external returns (uint[] memory) {
        uint[] memory errors = new uint[](0);
        return errors;
    }

    function exitMarket(address) external returns (uint) {
        return 0;
    }

    /*** Policy Hooks (all permissive) ***/

    function mintAllowed(address, address, uint) external returns (uint) {
        return 0;
    }

    function mintVerify(address, address, uint, uint) external {}

    function redeemAllowed(address, address, uint) external returns (uint) {
        return 0;
    }

    function redeemVerify(address, address, uint, uint) external {}

    function borrowAllowed(address, address, uint) external returns (uint) {
        return 0;
    }

    function borrowVerify(address, address, uint) external {}

    function repayBorrowAllowed(
        address,
        address,
        address,
        uint
    ) external returns (uint) {
        return 0;
    }

    function repayBorrowVerify(address, address, address, uint, uint) external {}

    function liquidateBorrowAllowed(
        address,
        address,
        address,
        address,
        uint
    ) external returns (uint) {
        return 0;
    }

    function liquidateBorrowVerify(address, address, address, address, uint, uint)
        external
    {}

    function seizeAllowed(address, address, address, address, uint)
        external
        returns (uint)
    {
        return 0;
    }

    function seizeVerify(address, address, address, address, uint) external {}

    function transferAllowed(address, address, address, uint)
        external
        returns (uint)
    {
        return 0;
    }

    function transferVerify(address, address, address, uint) external {}

    /*** Pricing & Liquidation ***/

    function getUnderlyingPrice(address) external pure returns (uint) {
        return 1e18;
    }

    /// @notice real comptroller formula with prices pinned to 1e18:
    /// seizeTokens = repayAmount * priceBorrowed * (1+incentive)
    ///              / priceCollateral / exchangeRateCollateral
    function liquidateCalculateSeizeTokens(
        address cTokenBorrowed,
        address cTokenCollateral,
        uint repayAmount
    ) external view returns (uint, uint) {
        uint exchangeRateMantissa = CToken(cTokenCollateral)
            .exchangeRateStored();
        if (exchangeRateMantissa == 0) {
            return (1, 0);
        }
        uint seizeTokens = (repayAmount * liquidationIncentiveMantissa) /
            exchangeRateMantissa;
        return (0, seizeTokens);
    }
}
