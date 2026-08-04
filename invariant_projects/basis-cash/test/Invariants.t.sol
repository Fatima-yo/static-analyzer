// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "./BasisCashHandler.sol";

contract BasisCashInvariants {
    BasisCashHandler internal h;

    address[] internal _targetedSenders;
    address[] internal _targetedContracts;

    constructor() public {
        h = new BasisCashHandler();
        _targetedContracts.push(address(h));
        _targetedSenders.push(0x2222000000000000000000000000000000000001);
        _targetedSenders.push(0x2222000000000000000000000000000000000002);
        _targetedSenders.push(0x2222000000000000000000000000000000000003);
        _targetedSenders.push(0x2222000000000000000000000000000000000004);
        _targetedSenders.push(0x2222000000000000000000000000000000000005);
        _targetedSenders.push(0x2222000000000000000000000000000000000006);
        _targetedSenders.push(0x2222000000000000000000000000000000000007);
        _targetedSenders.push(0x2222000000000000000000000000000000000008);
    }

    // Forge reads these getters to discover invariant targets (StdInvariant ABI).
    function targetSenders() public view returns (address[] memory) {
        return _targetedSenders;
    }

    function targetContracts() public view returns (address[] memory) {
        return _targetedContracts;
    }

    // A director can never earn cash from the boardroom beyond what was
    // allocated to it. Pending claims plus already-claimed cash must never
    // exceed total allocations. Catches the withdraw-retroactive-inflation
    // ("phantom reward") accounting gap.
    function invariant_earningsNeverExceedAllocated() public view {
        // require (not assert): in Solidity 0.6.x, assert(false) compiles to
        // the INVALID opcode, which Foundry reports as the opaque
        // "InvalidFEOpcode" instead of the assertion message.
        require(
            h.checkEarningsNeverExceedAllocated(),
            "VIOLATION: pending + claimed > allocated (phantom rewards)"
        );
    }

    // No reward can be claimed by an actor who never staked.
    function invariant_noRewardWithoutStake() public view {
        require(h.checkNoRewardWithoutStake(), "VIOLATION: reward without stake");
    }

    // Share tokens are conserved between actors, handler, and boardroom.
    function invariant_shareBooksBalance() public view {
        require(h.checkShareBooksBalance(), "VIOLATION: share not conserved");
    }
}
