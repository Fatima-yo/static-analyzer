// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;

import "./RocketHandler.sol";

// Echidna entry point for the rocket-pool rETH token-accounting harness.
//
// Echidna treats every `echidna_*` public view function as a property and
// fuzzes every other public function of the target contract. Composition
// (rather than inheritance) keeps the fuzz-target ABI explicit so the
// echidna.yaml filterFunctions whitelist matches cleanly.
contract EchidnaRocketPool {
    RocketHandler public h;

    constructor() public {
        h = new RocketHandler();
    }

    // ====== Forwarded fuzz actions ======

    function deposit(uint256 idx, uint256 amount) external {
        h.deposit(idx, amount);
    }

    function burn(uint256 idx, uint256 amount) external {
        h.burn(idx, amount);
    }

    // ====== Properties ======

    function echidna_eth_conserved() public view returns (bool) {
        return h.checkEthConservation();
    }

    function echidna_reth_supply_conserved() public view returns (bool) {
        return h.checkRethSupply();
    }

    function echidna_collateral_rate_bounded() public view returns (bool) {
        return h.checkCollateralRate();
    }

    function echidna_reth_fully_backed() public view returns (bool) {
        return h.checkBacking();
    }
}
