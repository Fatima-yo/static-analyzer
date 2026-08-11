// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./CometHandler.sol";

/// Echidna entry point for the Compound v3 (Comet) invariant harness.
///
/// Composition (rather than inheritance) keeps the fuzz-target ABI explicit so
/// the filterFunctions whitelist matches cleanly — the same pattern as the
/// morpho-blue, rocket-pool, kpk, hundred-bond, compound-v2, credit-guild and
/// balancer-v2 wrappers. (The handler already mod-reduces its `idx` args
/// internally, so no wrapper-level index clamping is needed here.)
contract EchidnaCompoundV3 {
    CometHandler public h;

    constructor() {
        h = new CometHandler();
    }

    // ====== Forwarded fuzz actions ======

    function supply(uint256 idx, uint256 amount) external {
        h.supply(idx, amount);
    }

    function withdraw(uint256 idx, uint256 amount) external {
        h.withdraw(idx, amount);
    }

    function transfer(uint256 idx, uint256 amount) external {
        h.transfer(idx, amount);
    }

    function absorb(uint256 idx, uint256 shockAmount) external {
        h.absorb(idx, shockAmount);
    }

    function buyCollateral(uint256 idx, uint256 amount) external {
        h.buyCollateral(idx, amount);
    }

    function pause(uint256 seed) external {
        h.pause(seed);
    }

    function warp(uint256 amount) external {
        h.warp(amount);
    }

    // ====== Properties ======

    function echidna_base_book_conserved() public view returns (bool) {
        return h.checkBaseBookConserved();
    }

    function echidna_collateral_book_conserved_weth() public view returns (bool) {
        return h.checkCollateralBookConserved(0);
    }

    function echidna_collateral_book_conserved_wbtc() public view returns (bool) {
        return h.checkCollateralBookConserved(1);
    }

    function echidna_base_no_leak() public view returns (bool) {
        return h.checkBaseNoLeak();
    }

    function echidna_last_residual() public view returns (bool) {
        return h.checkLastResidual();
    }

    function echidna_absorb_accounting() public view returns (bool) {
        return h.checkAbsorbAccounting();
    }

    function echidna_market_solvent() public view returns (bool) {
        return h.checkMarketSolvent();
    }
}
