// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "./BalancerHandler.sol";

/// @notice Invariant suite for Balancer V2's Vault. The fuzzer drives only the
/// handler (raw StdInvariant ABI, no forge-std dependency), so every state
/// mutation flows through the real Vault code with a real pranked user.
contract BalancerInvariants {
    BalancerHandler internal h;

    address[] internal _targetedContracts;
    address[] internal _targetedSenders;

    constructor() public {
        h = new BalancerHandler();
        _targetedContracts.push(address(h));
        for (uint256 i = 0; i < 8; ++i) {
            _targetedSenders.push(h.actors(i));
        }
    }

    function targetContracts() public view returns (address[] memory) {
        return _targetedContracts;
    }

    function targetSenders() public view returns (address[] memory) {
        return _targetedSenders;
    }

    function invariant_tokenA_conservation() public view {
        require(h.checkTokenConservation(0), "VIOLATION: Token A not conserved");
    }

    function invariant_tokenB_conservation() public view {
        require(h.checkTokenConservation(1), "VIOLATION: Token B not conserved");
    }

    function invariant_tokenC_conservation() public view {
        require(h.checkTokenConservation(2), "VIOLATION: Token C not conserved");
    }

    function invariant_vaultLedger_tokenA() public view {
        require(h.checkVaultLedger(0), "VIOLATION: Vault ledger mismatch for Token A");
    }

    function invariant_vaultLedger_tokenB() public view {
        require(h.checkVaultLedger(1), "VIOLATION: Vault ledger mismatch for Token B");
    }

    function invariant_vaultLedger_tokenC() public view {
        require(h.checkVaultLedger(2), "VIOLATION: Vault ledger mismatch for Token C");
    }

    function invariant_pool0_shares() public view {
        require(h.checkPoolShares(0), "VIOLATION: Pool A-B shares not conserved");
    }

    function invariant_pool1_shares() public view {
        require(h.checkPoolShares(1), "VIOLATION: Pool B-C shares not conserved");
    }
}
