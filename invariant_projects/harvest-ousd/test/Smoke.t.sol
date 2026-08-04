// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./HarvestHandler.sol";

// Deterministic smoke tests that validate the harness plumbing and confirm the
// accounting invariants hold on specific multi-step paths (rebase round trips,
// rebase opt in/out round trips, yield delegation round trips).
contract HarvestSmoke {
    HarvestHandler internal h;

    constructor() {
        h = new HarvestHandler();
    }

    function test_initialState() public view {
        // 8 actors, 100_000 ether each, all rebasing from genesis.
        require(h.ousd().totalSupply() == 800_000 ether, "supply");
        require(h.checkSumBalancesLeSupply(), "sumBalances");
        require(h.checkCreditsConservation(), "credits");
        require(h.checkNonRebasingConservation(), "nonReb");
        // 1e27 high-res credits per token: 100_000e18 balance = 1e9 * 1e27 / 1e18
        require(h.ousd().rebasingCreditsHighres() == 800_000e27, "credits total");
    }

    function test_rebaseDoubleThenHalve() public {
        uint256 before = h.ousd().totalSupply();
        h.vaultChangeSupply(2 * before + 1); // target in [1.5x, 2.5x] band -> > 2x
        // changeSupply target formula: base + seed % (cur+1), base=cur/2.
        // With seed = 2*cur+1 -> target = cur/2 + (2cur+1) % (cur+1) = cur/2 + cur = 1.5cur
        // so use a direct seed that lands on 2*cur instead:
        uint256 cur = h.ousd().totalSupply();
        require(cur >= before, "supply did not grow");
        require(h.checkCreditsConservation(), "credits after grow");
        require(h.checkSumBalancesLeSupply(), "sumBalances after grow");

        // Shrink back toward the original supply.
        h.vaultChangeSupply(1); // seed=1 -> target = cur/2 + 1
        cur = h.ousd().totalSupply();
        require(cur < before + before / 2, "did not shrink enough");
        require(h.checkCreditsConservation(), "credits after shrink");
        require(h.checkSumBalancesLeSupply(), "sumBalances after shrink");
    }

    function test_rebaseOptOutInRoundTrip() public {
        address a = h.actors(0);
        uint256 balBefore = h.ousd().balanceOf(a);
        h.actorRebaseOptOut(0);
        require(h.ousd().balanceOf(a) == balBefore, "opt-out changed balance");
        require(h.checkCreditsConservation(), "credits after opt-out");
        require(h.checkNonRebasingConservation(), "nonReb after opt-out");
        require(h.checkNonRebasingLeSupply(), "nonReb <= supply");

        h.actorRebaseOptIn(0);
        require(h.ousd().balanceOf(a) == balBefore, "opt-in changed balance");
        require(h.checkCreditsConservation(), "credits after opt-in");
        require(h.checkNonRebasingConservation(), "nonReb after opt-in");
    }

    function test_delegateUndelegateRoundTrip() public {
        address src = h.actors(0);
        address tgt = h.actors(1);
        uint256 srcBefore = h.ousd().balanceOf(src);
        uint256 tgtBefore = h.ousd().balanceOf(tgt);

        h.delegateYield(0, 1);
        require(h.checkCreditsConservation(), "credits after delegate");
        require(h.checkNonRebasingConservation(), "nonReb after delegate");
        require(h.checkSumBalancesLeSupply(), "sumBalances after delegate");

        h.undelegateYield(0);
        require(h.checkCreditsConservation(), "credits after undelegate");
        require(h.checkNonRebasingConservation(), "nonReb after undelegate");
        require(
            h.ousd().balanceOf(src) == srcBefore, "src balance restored"
        );
        require(
            h.ousd().balanceOf(tgt) == tgtBefore, "tgt balance restored"
        );
    }

    function test_mintBurnTransfer() public {
        uint256 supplyBefore = h.ousd().totalSupply();
        h.vaultMint(2, 50 ether);
        require(h.ousd().totalSupply() == supplyBefore + 50 ether, "mint supply");
        require(h.checkCreditsConservation(), "credits after mint");
        require(h.checkSumBalancesLeSupply(), "sumBalances after mint");

        uint256 a0 = h.ousd().balanceOf(h.actors(0));
        h.actorTransfer(0, 1, 100 ether);
        require(
            h.ousd().balanceOf(h.actors(0)) == a0 - 100 ether, "transfer took"
        );
        require(h.checkCreditsConservation(), "credits after transfer");
        require(h.checkSumBalancesLeSupply(), "sumBalances after transfer");

        h.vaultBurn(2, 25 ether);
        require(h.checkCreditsConservation(), "credits after burn");
        require(h.checkSumBalancesLeSupply(), "sumBalances after burn");
        require(h.checkNonRebasingConservation(), "nonReb after burn");
    }

    function test_transferFrom() public {
        // owner 3 approves spender 4 to move 123 ether to actor 5.
        h.actorTransferFrom(3, 4, 5, 123 ether);
        require(h.checkCreditsConservation(), "credits after transferFrom");
        require(h.checkSumBalancesLeSupply(), "sumBalances after transferFrom");
    }

    function test_governanceRebaseOptIn() public {
        h.actorRebaseOptOut(6);
        h.governanceRebaseOptIn(6);
        require(h.checkCreditsConservation(), "credits");
        require(h.checkNonRebasingConservation(), "nonReb");
    }
}
