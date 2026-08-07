// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./KpkHandler.sol";

/// Echidna entry point for the kpk KpkShares fund-vault harness.
///
/// Echidna treats every `echidna_*` public view function as a property and
/// fuzzes every other public function of the target contract (filtered by
/// echidna.yaml). Composition (rather than inheritance) keeps the fuzz-target
/// ABI explicit so the filterFunctions whitelist matches cleanly — the same
/// pattern as the rocket-pool and morpho-blue wrappers.
contract EchidnaKpk {
    KpkHandler public h;

    constructor() {
        h = new KpkHandler();
    }

    // ====== Forwarded fuzz actions ======

    function requestSubscriptionAction(uint256 idx, uint256 amount) external {
        h.requestSubscriptionAction(idx, amount);
    }

    function cancelSubscriptionAction(uint256 idx, uint256 seed) external {
        h.cancelSubscriptionAction(idx, seed);
    }

    function requestRedemptionAction(uint256 idx, uint256 amount) external {
        h.requestRedemptionAction(idx, amount);
    }

    function cancelRedemptionAction(uint256 idx, uint256 seed) external {
        h.cancelRedemptionAction(idx, seed);
    }

    function processAction(uint256 idx, uint256 seed) external {
        h.processAction(idx, seed);
    }

    function recoverAction(uint256 idx) external {
        h.recoverAction(idx);
    }

    function updateAssetAction(uint256 idx, uint256 seed) external {
        h.updateAssetAction(idx, seed);
    }

    function setterAction(uint256 idx, uint256 seed) external {
        h.setterAction(idx, seed);
    }

    function warp(uint256 amount) external {
        h.warp(amount);
    }

    // ====== Properties ======

    /// totalSupply == redemption escrow + fee receivers A/B + all actor balances.
    function echidna_share_book() public view returns (bool) {
        return h.checkShareBook();
    }

    /// asset.balanceOf(vault) == subscriptionAssets[asset] for all 3 assets.
    function echidna_asset_escrow() public view returns (bool) {
        return h.checkAssetEscrow();
    }
}
