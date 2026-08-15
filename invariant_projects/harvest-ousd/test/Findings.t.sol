// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./HarvestHandler.sol";

// Confirmed finding (from the invariant fuzzer):
//   harvest OUSD yield delegation + negative rebase -> balanceOf(target)
//   underflows (panic 0x11), locking the delegation target's account.
//
// Mechanism (OUSD.sol):
//   * delegateYield() sets creditBalances[target] = combined credits of
//     source+target and FREEZES creditBalances[source] at its balance
//     (OUSD.sol:674-687). The source's balance never rebases again.
//   * balanceOf() for a YieldDelegationTarget subtracts the fixed source
//     credits from the rebased combined balance (OUSD.sol:191-194).
//   * On a negative rebase changeSupply() grows rebasingCreditsPerToken_
//     (OUSD.sol:613-617); the combined credits convert to fewer tokens, and
//     once the rebased combined value drops below the frozen source credits
//     the subtraction underflows and every read/transfer on the target reverts.
contract HarvestFindings {
    HarvestHandler internal h;

    constructor() {
        h = new HarvestHandler();
    }

    // Fuzzer counterexample (shrunk to 3 calls):
    //   delegateYield(4->2) -> actorRebaseOptOut(6) -> vaultChangeSupply(1228)
    // reproduced by the invariant runner as panic 0x11 in checkSumBalancesLeSupply.
    function test_yieldDelegationNegativeRebaseLocksTarget() public {
        address src = h.actors(4);
        address tgt = h.actors(2);

        h.delegateYield(204, 50); // from = actor[204%8=4], to = actor[50%8=2]
        h.actorRebaseOptOut(254); // actor[254%8=6] opts out (raises non-rebasing supply)

        uint256 supplyBefore = h.ousd().totalSupply();
        h.vaultChangeSupply(1228); // shrink to ~cur/2
        require(h.ousd().totalSupply() < supplyBefore, "supply must shrink");

        // The source is fully insulated from the negative rebase...
        require(h.ousd().balanceOf(src) == 100_000 ether, "source fixed");

        // ...while the target's balanceOf underflows outright.
        bool ok;
        try h.ousd().balanceOf(tgt) {
            ok = true;
        } catch {
            ok = false;
        }
        require(!ok, "balanceOf(target) underflows after negative rebase");

        // Every transfer from the target also reverts -> funds locked.
        ok = false;
        try h.actorTransfer(2, 3, 1) {
            ok = true;
        } catch {
            ok = false;
        }
        require(!ok, "target transfer reverts (locked)");
    }

    // Same underflow reachable with repeated halvings and no opt-out: two
    // consecutive changeSupply(0) calls halve supply twice (cpt 1e27 -> 2e27
    // -> 4e27), crossing the 2e27 threshold for the combined delegation credits.
    function test_yieldDelegationDoubleHalveLocksTarget() public {
        address tgt = h.actors(2);
        h.delegateYield(204, 50);
        h.vaultChangeSupply(0);
        h.vaultChangeSupply(0);
        bool ok;
        try h.ousd().balanceOf(tgt) {
            ok = true;
        } catch {
            ok = false;
        }
        require(!ok, "balanceOf(target) underflows after double halve");
    }
}
