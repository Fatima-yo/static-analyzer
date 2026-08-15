// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "./IonicHandler.sol";

/// @notice Invariant test harness for the Ionic CErc20Delegator diamond. Uses
/// the raw StdInvariant ABI: forge discovers the fuzz target via
/// `targetContracts()`/`targetSenders()` and drives the handler's public
/// actions with each targeted sender as msg.sender.
contract IonicInvariants {
    IonicHandler internal h;

    address[] internal _targetedSenders;
    address[] internal _targetedContracts;

    constructor() {
        h = new IonicHandler();
        _targetedContracts.push(address(h));
        uint160 base = uint160(0x1111000000000000000000000000000000000001);
        for (uint256 i = 0; i < 4; i++) {
            _targetedSenders.push(address(base + uint160(i)));
        }
    }

    // Forge reads these getters to discover invariant targets (StdInvariant ABI).
    function targetContracts() public view returns (address[] memory) {
        return _targetedContracts;
    }

    function targetSenders() public view returns (address[] memory) {
        return _targetedSenders;
    }

    // cTokens are conserved: totalSupply == sum of every holder's balance.
    function invariant_ctokenConservation() public view {
        require(h.checkCtokenConservation(), "VIOLATION: cToken not conserved");
    }

    // Underlying is conserved across actors, markets and the handler.
    function invariant_underlyingConservation() public view {
        require(h.checkUnderlyingConservation(), "VIOLATION: underlying not conserved");
    }

    // Per-borrower ledger matches totalBorrows (within per-account rounding).
    function invariant_borrowLedger() public view {
        require(h.checkBorrowSum(), "VIOLATION: borrow ledger mismatch");
    }
}
