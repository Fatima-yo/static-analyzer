// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import { ComptrollerV3Storage } from "../../src/compound/ComptrollerStorage.sol";
import { ICErc20 } from "../../src/compound/CTokenInterfaces.sol";

/// @notice Minimal permissive comptroller for the Ionic invariant harness.
/// Every policy hook returns NO_ERROR (0) so the fuzzer can reach all
/// accounting transitions including undercollateralized borrow states.
/// `liquidateCalculateSeizeTokens` is faithful to the real Comptroller:
///   totalPenalty = liquidationIncentive (1.08) + protocolSeizeShare (2.8%)
///                 + feeSeizeShare (10%)  =>  1.208e18
///   seizeTokens  = repayAmount * totalPenalty * priceBorrowed
///                / (priceCollateral * exchangeRate)
/// with both asset prices pinned to 1e18.
contract SimpleComptroller is ComptrollerV3Storage {
    constructor() {
        admin = msg.sender;
        adminHasRights = true;
        ionicAdminHasRights = true;
        _notEntered = true;
        liquidationIncentiveMantissa = 1.08e18;
    }

    function setMarket(address cToken, uint256 collateralFactorMantissa_) external {
        require(msg.sender == admin, "!admin");
        markets[cToken].isListed = true;
        markets[cToken].collateralFactorMantissa = collateralFactorMantissa_;
        allMarkets.push(ICErc20(cToken));
    }

    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata cTokens) external view returns (uint256[] memory errors) {
        errors = new uint256[](cTokens.length);
        for (uint256 i = 0; i < cTokens.length; i++) {
            if (!markets[cTokens[i]].isListed) errors[i] = 1;
        }
    }

    function exitMarket(address) external pure returns (uint256) {
        return 0;
    }

    /*** Policy Hooks (all permissive) ***/

    function mintAllowed(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function redeemAllowed(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function borrowAllowed(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function borrowWithinLimits(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function repayBorrowAllowed(address, address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function liquidateBorrowAllowed(address, address, address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function seizeAllowed(address, address, address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function transferAllowed(address, address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function getMaxRedeemOrBorrow(address, ICErc20, bool) external pure returns (uint256) {
        return type(uint256).max;
    }

    /*** Liquidity / Liquidation ***/

    function getHypotheticalAccountLiquidity(
        address,
        address,
        uint256,
        uint256,
        uint256
    ) external pure returns (uint256, uint256, uint256, uint256) {
        return (0, 0, 0, 0);
    }

    function getAccountLiquidity(
        address
    ) external pure returns (uint256, uint256, uint256, uint256) {
        return (0, 0, 0, 0);
    }

    function liquidateCalculateSeizeTokens(
        address,
        address cTokenCollateral,
        uint256 actualRepayAmount
    ) external view returns (uint256, uint256) {
        ICErc20 collateral = ICErc20(cTokenCollateral);
        uint256 exchangeRateMantissa = collateral.exchangeRateCurrent();
        if (exchangeRateMantissa == 0) {
            return (1, 0);
        }
        uint256 totalPenaltyMantissa =
            liquidationIncentiveMantissa +
            collateral.protocolSeizeShareMantissa() +
            collateral.feeSeizeShareMantissa();
        uint256 seizeTokens = (actualRepayAmount * totalPenaltyMantissa) / exchangeRateMantissa;
        return (0, seizeTokens);
    }

    /*** Pool-Wide/Cross-Asset Reentrancy Prevention ***/

    function _beforeNonReentrant() external {
        require(_notEntered, "re-entered");
        _notEntered = false;
    }

    function _afterNonReentrant() external {
        _notEntered = true;
    }
}
