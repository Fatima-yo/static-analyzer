// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./MorphoHandler.sol";

/// Echidna entry point for the morpho-blue Morpho lending-ledger harness.
///
/// Echidna treats every `echidna_*` public view function as a property and
/// fuzzes every other public function of the target contract (filtered by
/// echidna.yaml). Composition (rather than inheritance) keeps the fuzz-target
/// ABI explicit so the filterFunctions whitelist matches cleanly — the same
/// pattern as the rocket-pool wrapper.
contract EchidnaMorphoBlue {
    MorphoHandler public h;

    constructor() {
        h = new MorphoHandler();
    }

    // ====== Forwarded fuzz actions ======

    function supply(uint256 idx, uint256 amount) external {
        h.supply(idx, amount);
    }

    function supplyCollateral(uint256 idx, uint256 amount) external {
        h.supplyCollateral(idx, amount);
    }

    function borrow(uint256 idx, uint256 amount) external {
        h.borrow(idx, amount);
    }

    function withdraw(uint256 idx, uint256 amount) external {
        h.withdraw(idx, amount);
    }

    function withdrawCollateral(uint256 idx, uint256 amount) external {
        h.withdrawCollateral(idx, amount);
    }

    function repay(uint256 idx, uint256 amount) external {
        h.repay(idx, amount);
    }

    function liquidate(uint256 idx, uint256 amount) external {
        h.liquidate(idx, amount);
    }

    function accrue(uint256 idx) external {
        h.accrue(idx);
    }

    function warp(uint256 amount) external {
        h.warp(amount);
    }

    function setFee(uint256 idx, uint256 amount) external {
        h.setFee(idx, amount);
    }

    function setFeeRecipient(uint256 idx, uint256 amount) external {
        h.setFeeRecipient(idx, amount);
    }

    function setOwner(uint256 idx, uint256 amount) external {
        h.setOwner(idx, amount);
    }

    // ====== Properties ======

    function echidna_supply_shares_conserved_m0() public view returns (bool) {
        return h.checkSupplySharesConserved(0);
    }

    function echidna_supply_shares_conserved_m1() public view returns (bool) {
        return h.checkSupplySharesConserved(1);
    }

    function echidna_borrow_shares_conserved_m0() public view returns (bool) {
        return h.checkBorrowSharesConserved(0);
    }

    function echidna_borrow_shares_conserved_m1() public view returns (bool) {
        return h.checkBorrowSharesConserved(1);
    }

    function echidna_usdc_balance_conserved() public view returns (bool) {
        return h.checkTokenBalance(0);
    }

    function echidna_weth_balance_conserved() public view returns (bool) {
        return h.checkTokenBalance(1);
    }

    function echidna_usdc_ledger_residual() public view returns (bool) {
        return h.checkUsdcResidual();
    }

    function echidna_weth_ledger_residual() public view returns (bool) {
        return h.checkWethResidual();
    }

    function echidna_market_solvent_m0() public view returns (bool) {
        return h.checkMarketSolvent(0);
    }

    function echidna_market_solvent_m1() public view returns (bool) {
        return h.checkMarketSolvent(1);
    }
}
