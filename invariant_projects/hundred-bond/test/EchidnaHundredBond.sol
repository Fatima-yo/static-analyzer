// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./HundredBondHandler.sol";

/// Echidna entry point for the HundredBond invariant harness.
///
/// Composition (rather than inheritance) keeps the fuzz-target ABI explicit so
/// the filterFunctions whitelist matches cleanly — the same pattern as the
/// morpho-blue and rocket-pool wrappers.
contract EchidnaHundredBond {
    HundredBondHandler public h;

    constructor() {
        h = new HundredBondHandler();
    }

    // ====== Forwarded fuzz actions ======

    function ownerMint(uint8 actorIdx, uint256 amount) external {
        h.ownerMint(actorIdx, amount);
    }

    function actorBurn(uint8 actorIdx, uint256 amount) external {
        h.actorBurn(actorIdx, amount);
    }

    function actorRedeem(uint8 actorIdx) external {
        h.actorRedeem(actorIdx);
    }

    function warp(uint256 seconds_) external {
        h.warp(seconds_);
    }

    // ====== Properties ======

    function echidna_backing() public view returns (bool) {
        return h.checkBacking();
    }

    function echidna_bond_supply() public view returns (bool) {
        return h.checkBondSupply();
    }

    function echidna_hnd_conservation() public view returns (bool) {
        return h.checkHndConservation();
    }
}
