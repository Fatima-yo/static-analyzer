// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {MarketParams, Market} from "../core/interfaces/IMorpho.sol";

/// @notice Fixed-rate interest model for the morpho-blue harness. Returns a
/// constant per-second rate scaled by WAD (5% per year), so `_accrueInterest`
/// runs its real Taylor-compounded path on every time warp. State-free, never
/// re-enters Morpho (matches morpho-blue's IRM trust assumptions).
contract MockIrm {
    uint256 public immutable RATE;

    constructor(uint256 ratePerSecondWad) {
        RATE = ratePerSecondWad;
    }

    function borrowRate(MarketParams memory, Market memory) external view returns (uint256) {
        return RATE;
    }

    function borrowRateView(MarketParams memory, Market memory) external view returns (uint256) {
        return RATE;
    }
}
