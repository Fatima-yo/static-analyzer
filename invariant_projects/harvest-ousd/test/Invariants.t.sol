// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./HarvestHandler.sol";

contract HarvestInvariants {
    HarvestHandler internal h;

    address[] internal _targetedSenders;
    address[] internal _targetedContracts;

    constructor() {
        h = new HarvestHandler();
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

    function targetSenders() public view returns (address[] memory) {
        return _targetedSenders;
    }

    function targetContracts() public view returns (address[] memory) {
        return _targetedContracts;
    }

    // No inflation: sum of account balances never exceeds elastic supply.
    function invariant_sumBalancesLeSupply() public view {
        require(
            h.checkSumBalancesLeSupply(),
            "VIOLATION: sum(balances) > totalSupply (inflation)"
        );
    }

    // Credits bookkeeping: rebasingCredits_ == sum of rebasing creditBalances.
    function invariant_creditsConservation() public view {
        require(
            h.checkCreditsConservation(),
            "VIOLATION: rebasingCredits_ != sum(creditBalances)"
        );
    }

    // Non-rebasing bookkeeping: nonRebasingSupply == sum of non-rebasing
    // balances (StdNonRebasing accounts only).
    function invariant_nonRebasingConservation() public view {
        require(
            h.checkNonRebasingConservation(),
            "VIOLATION: nonRebasingSupply != sum(non-rebasing balances)"
        );
    }

    // nonRebasingSupply is always a component of totalSupply.
    function invariant_nonRebasingLeSupply() public view {
        require(
            h.checkNonRebasingLeSupply(),
            "VIOLATION: nonRebasingSupply > totalSupply"
        );
    }
}
