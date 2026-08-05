// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;

import "./RocketHandler.sol";

/// @notice Round-trip smoke tests over the Rocket Pool harness. No forge-std
/// dependency, matching the compound-v2 / hundred-bond / balancer-v2 playbook.
/// These pin the rETH accounting invariants against deterministic
/// deposit/mint/burn/transfer/stake/excess-collateral flows before the fuzzer
/// is let loose, and reproduce the Phase-1 "rETH oracle burn" (score 11) as an
/// oracle-trust boundary.
contract RocketSmokeTests {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    RocketHandler internal h;

    constructor() public {
        h = new RocketHandler();
    }

    function test_mint_burn_roundtrip() public {
        h.depositAndMint(0, 100 ether);
        h.advanceBlocks(h.DEPOSIT_DELAY() + 1);

        uint256 ethBefore = h.actors(0).balance;
        uint256 rethBefore = h.reth().balanceOf(h.actors(0));

        h.burn(0, 100 ether);

        require(h.reth().balanceOf(h.actors(0)) == rethBefore - 100 ether, "rETH not burned");
        require(h.actors(0).balance == ethBefore + 100 ether, "ETH not returned 1:1");

        require(h.checkBacking(), "backing broken");
        require(h.checkCollateralRate(), "rate broken");
        require(h.checkEthConservation(), "ETH not conserved");
        require(h.checkRethSupply(), "supply broken");
    }

    function test_deposit_delay_blocks_transfer() public {
        // The harness _tick() auto-advances the chain past DEPOSIT_DELAY, so
        // the handler no longer trips the protocol guard. Drive the protocol
        // directly to prove the guard itself still enforces the deposit delay.
        Actor from = Actor(h.actors(1));
        Actor to = Actor(h.actors(2));
        address reth = address(h.reth());

        from.deposit(address(h.depositPool()), 50 ether);

        VM.expectRevert("Not enough time has passed since deposit");
        from.transfer(reth, address(to), 10 ether);

        h.advanceBlocks(h.DEPOSIT_DELAY() + 1);
        from.transfer(reth, address(to), 10 ether);

        require(h.reth().balanceOf(address(to)) == 250 ether + 10 ether, "transfer failed");
        require(h.checkRethSupply(), "supply broken");
    }

    function test_burn_insufficient_liquidity_reverts() public {
        h.stake(1950 ether);

        VM.expectRevert("Insufficient ETH balance for exchange");
        h.burn(3, 100 ether);

        require(h.checkBacking(), "backing broken");
        require(h.checkEthConservation(), "ETH not conserved");
    }

    function test_oracle_inflate_drains_collateral() public {
        h.depositAndMint(2, 100 ether);
        h.advanceBlocks(h.DEPOSIT_DELAY() + 1);

        uint256 inflated = 2 * h.realBacking();
        h.oracle().submitBalances(block.number, inflated, 0, h.reth().totalSupply());

        uint256 ethBefore = h.actors(2).balance;
        h.burn(2, 100 ether);

        require(h.actors(2).balance - ethBefore > 100 ether, "burn did not overpay");
        require(!h.checkBacking(), "backing must break under inflated oracle");
    }

    function test_mint_gated_to_deposit_pool() public {
        RocketTokenRETH r = h.reth();
        address a = h.actors(0);
        VM.expectRevert("Invalid or outdated contract");
        r.mint(1 ether, a);
    }

    function test_collateral_rate_tracks_excess() public {
        require(h.reth().getCollateralRate() == 0, "initial rate not zero");

        h.depositExcess(500 ether);
        require(h.reth().getCollateralRate() == 0.25 ether, "rate not tracking excess");

        h.depositExcessCollateral();
        require(h.reth().getCollateralRate() == 0.25 ether, "rate changed below target");

        require(h.checkBacking(), "backing broken");
        require(h.checkEthConservation(), "ETH not conserved");
    }

    function test_deposit_excess_collateral_recycles() public {
        h.depositExcess(2000 ether);
        h.depositExcessCollateral();

        require(address(h.reth()).balance == 1800 ether, "excess not recycled");
        require(address(h.depositPool()).balance == 200 ether, "pool not credited");

        require(h.checkBacking(), "backing broken");
        require(h.checkEthConservation(), "ETH not conserved");
    }

    function test_transfer_after_delay_clears_flag() public {
        h.depositAndMint(4, 20 ether);
        h.advanceBlocks(h.DEPOSIT_DELAY() + 1);

        h.transfer(4, 5, 10 ether);
        h.transfer(4, 5, 10 ether);

        require(h.reth().balanceOf(h.actors(4)) == 250 ether, "flag not cleared");
        require(h.reth().balanceOf(h.actors(5)) == 270 ether, "wrong recipient balance");
        require(h.checkRethSupply(), "supply broken");
    }
}
