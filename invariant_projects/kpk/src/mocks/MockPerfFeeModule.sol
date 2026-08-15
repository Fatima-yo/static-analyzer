// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/// @notice Deterministic performance-fee module for the kpk harness. The real
/// deployment's module is external; this mock mirrors the shape of the
/// interface (price-, time- and supply-proportional, capped at netSupply so a
/// single fee can never mint more shares than are already outstanding).
contract MockPerfFeeModule {
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    function calculatePerformanceFee(uint256 sharesPrice, uint256 timeElapsed, uint256 feePct, uint256 netSupply)
        external
        returns (uint256)
    {
        uint256 t = timeElapsed > SECONDS_PER_YEAR ? SECONDS_PER_YEAR : timeElapsed;
        uint256 fee = (netSupply * feePct * t * sharesPrice) / (1e4 * SECONDS_PER_YEAR * 1e8);
        if (fee > netSupply) fee = netSupply;
        return fee;
    }
}
