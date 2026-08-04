// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./HundredBondHandler.sol";
import "../src/HundredBond.sol";
import "./Hnd.sol";
import "./MockEscrow.sol";

/// @notice Round-trip smoke tests over the hundred-bond harness (Polygon v2
/// escrow path). No forge-std dependency, matching the compound-v2 playbook.
contract HundredBondSmoke {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    HundredBondHandler internal h;
    HundredBond internal bond;
    Hnd internal hnd;
    MockEscrow internal escrow;

    constructor() public {
        h = new HundredBondHandler();
        bond = h.bond();
        hnd = h.hnd();
        escrow = h.escrow();
    }

    function _actor(uint8 i) internal view returns (address) {
        return address(h.actors(i % 8));
    }

    function test_mint_backs_bond() public {
        h.ownerMint(0, 100 ether);
        require(bond.balanceOf(_actor(0)) == 100 ether, "wrong HNDb minted");
        require(hnd.balanceOf(address(bond)) == 100 ether, "HND not pulled");
        require(h.checkBacking(), "backing broken");
        require(h.checkHndConservation(), "HND leaked");
    }

    function test_burn_returns_hnd_to_owner() public {
        h.ownerMint(0, 100 ether);
        VM.prank(_actor(0));
        bond.burn(40 ether);

        require(bond.balanceOf(_actor(0)) == 60 ether, "wrong burn");
        require(hnd.balanceOf(address(bond)) == 60 ether, "backing not reduced");
        // the bond's owner is the handler; the HND backing returns to it
        require(hnd.balanceOf(address(h)) == 1_000_000 ether - 60 ether, "owner balance");
        require(h.checkBacking(), "backing broken");
        require(h.checkHndConservation(), "HND leaked");
    }

    function test_redeem_locks_hnd_into_escrow() public {
        h.ownerMint(0, 100 ether);
        VM.prank(_actor(0));
        bond.redeem();

        require(bond.balanceOf(_actor(0)) == 0, "HNDb not burned");
        require(bond.totalSupply() == 0, "supply not zero");
        require(hnd.balanceOf(address(bond)) == 0, "backing not moved");
        require(h.checkBacking(), "backing broken");

        LockedBalance memory l = escrow.locked(_actor(0));
        require(uint256(int256(l.amount)) == 100 ether, "wrong locked amount");
        require(l.end == block.timestamp + h.BOND_UNLOCK_DURATION(), "wrong lock end");
    }

    function test_redeem_twice_same_lock_grows() public {
        h.ownerMint(0, 100 ether);
        VM.prank(_actor(0));
        bond.redeem();
        h.ownerMint(0, 50 ether);
        VM.prank(_actor(0));
        bond.redeem();

        LockedBalance memory l = escrow.locked(_actor(0));
        require(uint256(int256(l.amount)) == 150 ether, "lock did not grow");
        require(h.checkBacking(), "backing broken");
        require(h.checkHndConservation(), "HND leaked");
    }

    function test_redeem_after_lock_expiry_reverts() public {
        h.ownerMint(0, 100 ether);
        VM.prank(_actor(0));
        bond.redeem();

        VM.warp(block.timestamp + h.BOND_UNLOCK_DURATION() + 1);
        h.ownerMint(0, 50 ether);
        VM.prank(_actor(0));
        VM.expectRevert(bytes("HND lock needs to be extended"));
        bond.redeem();

        require(h.checkBacking(), "backing broken");
        require(h.checkHndConservation(), "HND leaked");
    }

    function test_burn_is_owner_payout_not_user() public {
        // Burning returns the HND backing to the OWNER, never to the user.
        h.ownerMint(0, 100 ether);
        uint256 hndBefore = hnd.balanceOf(address(h));
        VM.prank(_actor(0));
        bond.burn(100 ether);

        require(hnd.balanceOf(address(h)) == hndBefore + 100 ether, "owner not paid");
        require(hnd.balanceOf(_actor(0)) == 0, "user received HND");
        require(h.checkHndConservation(), "HND leaked");
    }

    function test_rescue_hnd_gated_until_rescue_time() public {
        // the handler is the bond's owner; prank as it to pass onlyOwner
        VM.prank(address(h));
        VM.expectRevert(bytes("Cannot rescue before 1 year"));
        bond.rescueHnd();

        VM.warp(bond.hndRescueTime() + 1);
        VM.prank(address(h));
        bond.rescueHnd();

        require(hnd.balanceOf(address(bond)) == 0, "rescue did not drain");
        require(hnd.balanceOf(address(h)) == 1_000_000 ether, "owner not paid");
        require(h.checkHndConservation(), "HND leaked");
    }

    function test_v1_redeem_always_reverts() public {
        // v1 escrow path: the bond transfers HND to the user first, then asks
        // the escrow to pull the same amount from ITSELF without any approve.
        // Against a veCRV-semantics escrow (transferFrom(msg.sender)), redeem
        // always reverts.
        address a = _actor(0);
        Hnd hnd2 = new Hnd();
        MockEscrow escrow2 = new MockEscrow(hnd2);
        HundredBond bond1 = new HundredBond(hnd2, escrow2, false, h.BOND_UNLOCK_DURATION());

        hnd2.approve(address(bond1), type(uint256).max);
        bond1.mint(a, 100 ether);

        // give the user a long-lived pre-existing lock so the v1 `require`
        // (locked_.end >= unlockTime_) passes
        hnd2.transfer(a, 100 ether);
        VM.prank(a);
        hnd2.approve(address(escrow2), 100 ether);
        VM.prank(a);
        escrow2.create_lock_for(a, 100 ether, block.timestamp + 365 days);

        VM.prank(a);
        try bond1.redeem() {
            revert("v1 redeem unexpectedly succeeded");
        } catch {}

        // the atomic revert leaves the user's HNDb and the bond's backing intact
        require(bond1.balanceOf(a) == 100 ether, "HNDb moved despite revert");
        require(hnd2.balanceOf(address(bond1)) == 100 ether, "backing moved despite revert");
    }

    function test_mint_paused_reverts() public {
        address a = _actor(0);
        VM.prank(address(h));
        bond.pause();
        VM.prank(address(h));
        VM.expectRevert(bytes("Pausable: paused"));
        bond.mint(a, 1 ether);
        VM.prank(address(h));
        bond.unPause();
        VM.prank(address(h));
        bond.mint(a, 1 ether);
        require(bond.balanceOf(a) == 1 ether, "mint after unpause failed");
    }
}
