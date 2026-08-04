// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "./BasisCashHandler.sol";

// Echidna entry point for the basis-cash Boardroom harness.
//
// Echidna treats every `echidna_*` public view function as a property and
// fuzzes every other public function of the target contract. Composition
// (rather than inheritance) keeps the fuzz-target ABI explicit so the
// echidna.yaml filterFunctions whitelist matches cleanly.
contract EchidnaBasisCash {
    BasisCashHandler public h;

    constructor() public {
        h = new BasisCashHandler();
    }

    // ====== Forwarded fuzz actions ======

    function actorStake(uint8 actorIdx, uint256 amount) external {
        h.actorStake(actorIdx, amount);
    }

    function actorWithdraw(uint8 actorIdx, uint256 amount) external {
        h.actorWithdraw(actorIdx, amount);
    }

    function actorClaim(uint8 actorIdx) external {
        h.actorClaim(actorIdx);
    }

    function allocateSeigniorage(uint256 amount) external {
        h.allocateSeigniorage(amount);
    }

    function warpDays(uint256 numDays) external {
        h.warpDays(numDays);
    }

    // ====== Properties ======

    // Conservation: pending claims + already-claimed cash must never exceed
    // total seigniorage allocated to the boardroom.
    function echidna_earnings_never_exceed_allocated()
        public
        view
        returns (bool)
    {
        return h.checkEarningsNeverExceedAllocated();
    }

    // No reward can be claimed by an actor who never staked (zero shares).
    function echidna_no_reward_without_stake() public view returns (bool) {
        return h.checkNoRewardWithoutStake();
    }

    // Share tokens are conserved: actors + boardroom == total supply.
    function echidna_share_books_balance() public view returns (bool) {
        return h.checkShareBooksBalance();
    }
}
