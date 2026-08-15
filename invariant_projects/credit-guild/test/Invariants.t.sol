// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./CreditGuildHandler.sol";

contract CreditGuildInvariants {
    CreditGuildHandler internal h;

    address[] internal _targetedSenders;
    address[] internal _targetedContracts;

    constructor() {
        h = new CreditGuildHandler();
        _targetedContracts.push(address(h));
        _targetedSenders.push(0x1111000000000000000000000000000000000001);
        _targetedSenders.push(0x1111000000000000000000000000000000000002);
        _targetedSenders.push(0x1111000000000000000000000000000000000003);
        _targetedSenders.push(0x1111000000000000000000000000000000000004);
        _targetedSenders.push(0x1111000000000000000000000000000000000005);
        _targetedSenders.push(0x1111000000000000000000000000000000000006);
        _targetedSenders.push(0x1111000000000000000000000000000000000007);
        _targetedSenders.push(0x1111000000000000000000000000000000000008);
    }

    // Forge reads these getters to discover invariant targets (StdInvariant ABI).
    function targetSenders() public view returns (address[] memory) {
        return _targetedSenders;
    }

    function targetContracts() public view returns (address[] memory) {
        return _targetedContracts;
    }

    // CREDIT tokens are conserved: no account can create or destroy value.
    function invariant_creditConservation() public view {
        require(h.checkCreditConservation(), "VIOLATION: CREDIT not conserved");
    }

    // GUILD tokens are conserved.
    function invariant_guildConservation() public view {
        require(h.checkGuildConservation(), "VIOLATION: GUILD not conserved");
    }

    // Gauge weight accounting is exact at the user, gauge, and global levels.
    function invariant_gaugeWeightConservation() public view {
        require(
            h.checkGaugeWeightConservation(),
            "VIOLATION: gauge weight not conserved"
        );
    }

    // Delegated votes balance against received votes.
    function invariant_votesConservation() public view {
        require(
            h.checkVotesConservation(),
            "VIOLATION: votes not conserved"
        );
    }

    // Collateral backing open loans always matches the terms' collateral.
    function invariant_collateralConservation() public view {
        require(
            h.checkCollateralConservation(),
            "VIOLATION: collateral not conserved"
        );
    }

    // ProfitManager issuance ledger matches the lending terms.
    function invariant_issuanceConsistency() public view {
        require(
            h.checkIssuanceConsistency(),
            "VIOLATION: issuance ledger mismatch"
        );
    }

    // Issuance never exceeds hard caps / global cap.
    function invariant_issuanceWithinCaps() public view {
        require(
            h.checkIssuanceWithinCaps(),
            "VIOLATION: issuance above cap"
        );
    }
}
