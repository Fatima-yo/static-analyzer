// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import { InterestRateModel } from "../../src/compound/InterestRateModel.sol";

/// @notice Constant-rate interest model for the Ionic harness. The rate must
/// stay below CTokenFirstExtension's `borrowRateMaxMantissa` (0.0005e16 =
/// 5e12) or the `!borrowRate` revert trips whenever the market holds cash.
contract SimpleInterestRateModel is InterestRateModel {
    uint256 public constant borrowRatePerBlock = 3e12;

    function getBorrowRate(
        uint256,
        uint256,
        uint256
    ) public pure override returns (uint256) {
        return borrowRatePerBlock;
    }

    function getSupplyRate(
        uint256,
        uint256,
        uint256,
        uint256
    ) public pure override returns (uint256) {
        return 0;
    }
}
