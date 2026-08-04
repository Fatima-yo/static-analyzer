// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./HundredBondHandler.sol";

/// @notice Invariant suite for Hundred Finance HundredBond (Polygon, v2 escrow).
/// The fuzzer drives the handler, which owns the bond and backs every mint
/// 1:1. Every action (mint / burn / redeem / warp) must conserve HND and keep
/// the HNDb supply exactly backed. Mirrors the compound-v2 harness: raw
/// StdInvariant ABI, no forge-std dependency.
contract HundredBondInvariants {
    HundredBondHandler internal h;

    address[] internal _targetedContracts;
    address[] internal _targetedSenders;

    constructor() public {
        h = new HundredBondHandler();
        _targetedContracts.push(address(h));
        for (uint256 i = 0; i < 8; i++) {
            _targetedSenders.push(h.actors(i));
        }
    }

    // Forge reads these getters to discover invariant targets (StdInvariant ABI).
    function targetContracts() public view returns (address[] memory) {
        return _targetedContracts;
    }

    function targetSenders() public view returns (address[] memory) {
        return _targetedSenders;
    }

    // Every HNDb in circulation is backed 1:1 by HND sitting in the bond.
    function invariant_hndbIsBacked() public view {
        require(h.checkBacking(), "VIOLATION: HNDb not backed 1:1 by HND");
    }

    // HNDb ERC20 exactness: supply == sum of holder balances.
    function invariant_hndbSupply() public view {
        require(h.checkBondSupply(), "VIOLATION: HNDb supply not conserved");
    }

    // HND is conserved across owner/bond/escrow/actors.
    function invariant_hndConservation() public view {
        require(h.checkHndConservation(), "VIOLATION: HND leaked or created");
    }
}
