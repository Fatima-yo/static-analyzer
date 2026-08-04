pragma solidity ^0.5.8;

import "./CompoundV2Handler.sol";

contract CompoundV2Invariants {
    CompoundV2Handler internal h;

    address[] internal _targetedSenders;
    address[] internal _targetedContracts;

    constructor() public {
        h = new CompoundV2Handler();
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
    function targetContracts() public view returns (address[] memory) {
        return _targetedContracts;
    }

    function targetSenders() public view returns (address[] memory) {
        return _targetedSenders;
    }

    // cTokens are conserved: totalSupply == sum of every holder's balance.
    function invariant_ctokenConservation() public view {
        require(
            h.checkCtokenConservation(),
            "VIOLATION: cToken not conserved"
        );
    }

    // Underlying ETH is conserved across actors, both markets and the handler.
    function invariant_ethConservation() public view {
        require(
            h.checkEthConservation(),
            "VIOLATION: underlying ETH not conserved"
        );
    }

    // Per-borrower ledger matches totalBorrows (within per-account rounding).
    function invariant_borrowLedger() public view {
        require(h.checkBorrowSum(), "VIOLATION: borrow ledger mismatch");
    }
}
