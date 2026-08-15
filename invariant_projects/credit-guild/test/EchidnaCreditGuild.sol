// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./CreditGuildHandler.sol";

/// Echidna entry point for the Ethereum Credit Guild (ECG) invariant harness.
///
/// Composition (rather than inheritance) keeps the fuzz-target ABI explicit so
/// the filterFunctions whitelist matches cleanly — the same pattern as the
/// morpho-blue, rocket-pool, kpk, hundred-bond and compound-v2 wrappers.
contract EchidnaCreditGuild {
    CreditGuildHandler public h;

    constructor() {
        h = new CreditGuildHandler();
    }

    // ====== Forwarded fuzz actions ======

    function actorBorrow(uint8 actorIdx, uint8 termChoice, uint256 borrowAmount, uint256 collateralAmount) external {
        h.actorBorrow(actorIdx, termChoice, borrowAmount, collateralAmount);
    }

    function actorAddCollateral(uint8 actorIdx, uint256 loanIdxSeed, uint256 amount) external {
        h.actorAddCollateral(actorIdx, loanIdxSeed, amount);
    }

    function actorPartialRepay(uint8 actorIdx, uint256 loanIdxSeed, uint256 amount) external {
        h.actorPartialRepay(actorIdx, loanIdxSeed, amount);
    }

    function actorRepay(uint8 actorIdx, uint256 loanIdxSeed) external {
        h.actorRepay(actorIdx, loanIdxSeed);
    }

    function actorCall(uint8 actorIdx, uint256 loanIdxSeed) external {
        h.actorCall(actorIdx, loanIdxSeed);
    }

    function actorBid(uint8 actorIdx, uint256 loanIdxSeed) external {
        h.actorBid(actorIdx, loanIdxSeed);
    }

    function actorForgive(uint8 actorIdx, uint256 loanIdxSeed) external {
        h.actorForgive(actorIdx, loanIdxSeed);
    }

    function actorDonateSurplus(uint8 actorIdx, uint256 amount) external {
        h.actorDonateSurplus(actorIdx, amount);
    }

    function actorIncrementGauge(uint8 actorIdx, uint8 termChoice, uint256 weight) external {
        h.actorIncrementGauge(actorIdx, termChoice, weight);
    }

    function actorDecrementGauge(uint8 actorIdx, uint8 termChoice, uint256 weight) external {
        h.actorDecrementGauge(actorIdx, termChoice, weight);
    }

    function actorTransferGuild(uint8 fromIdx, uint8 toIdx, uint256 amount) external {
        h.actorTransferGuild(fromIdx, toIdx, amount);
    }

    function actorTransferCredit(uint8 fromIdx, uint8 toIdx, uint256 amount) external {
        h.actorTransferCredit(fromIdx, toIdx, amount);
    }

    function actorTransferCollateral(uint8 fromIdx, uint8 toIdx, uint256 amount) external {
        h.actorTransferCollateral(fromIdx, toIdx, amount);
    }

    function actorApplyLoss(uint8 actorIdx, uint8 termChoice) external {
        h.actorApplyLoss(actorIdx, termChoice);
    }

    function actorClaimRewards(uint8 actorIdx) external {
        h.actorClaimRewards(actorIdx);
    }

    function actorEnterRebase(uint8 actorIdx) external {
        h.actorEnterRebase(actorIdx);
    }

    function actorExitRebase(uint8 actorIdx) external {
        h.actorExitRebase(actorIdx);
    }

    function warpDays(uint256 days_) external {
        h.warpDays(days_);
    }

    // ====== Properties ======

    function echidna_credit_conservation() public view returns (bool) {
        return h.checkCreditConservation();
    }

    function echidna_guild_conservation() public view returns (bool) {
        return h.checkGuildConservation();
    }

    function echidna_gauge_weight_conservation() public view returns (bool) {
        return h.checkGaugeWeightConservation();
    }

    function echidna_votes_conservation() public view returns (bool) {
        return h.checkVotesConservation();
    }

    function echidna_collateral_conservation() public view returns (bool) {
        return h.checkCollateralConservation();
    }

    function echidna_issuance_consistency() public view returns (bool) {
        return h.checkIssuanceConsistency();
    }

    function echidna_issuance_within_caps() public view returns (bool) {
        return h.checkIssuanceWithinCaps();
    }
}
