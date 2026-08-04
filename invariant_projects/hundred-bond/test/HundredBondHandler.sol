// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/HundredBond.sol";
import "./Hnd.sol";
import "./MockEscrow.sol";

interface Vm {
    function warp(uint256) external;
    function startPrank(address) external;
    function stopPrank() external;
    function prank(address) external;
    function expectRevert(bytes calldata) external;
}

/// @notice Invariant harness for Hundred Finance's HundredBond (Polygon
/// variant, escrow_is_v2 = true). The handler is the bond's owner; it holds
/// the HND backing, approves the bond once, and routes user actions (burn,
/// redeem) through 8 actor addresses via prank (safe: no action attaches
/// `msg.value`; every HND flow is an atomic ERC20 transferFrom/transfer).
contract HundredBondHandler {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint public constant BOND_UNLOCK_DURATION = 30 days;

    HundredBond public bond;
    Hnd public hnd;
    MockEscrow public escrow;

    address[8] public actors;

    /// @notice total HND in the system (owner/handler + bond + escrow +
    /// actors), minted to the handler at deploy; every action must conserve it.
    uint public initialHnd;

    constructor() public {
        for (uint256 i = 0; i < actors.length; i++) {
            actors[i] = address(uint160(0x11110000000000000000000000000000000000 + i + 1));
        }

        hnd = new Hnd();
        escrow = new MockEscrow(hnd);
        bond = new HundredBond(hnd, escrow, true, BOND_UNLOCK_DURATION);

        // handler is the bond owner and the sole HND holder; fund the mint path
        hnd.approve(address(bond), type(uint256).max);

        initialHnd = hnd.totalSupply();
    }

    // ============================================================
    //  Actions
    // ============================================================

    /// @notice owner-side bond sale: pulls HND backing from the handler into
    /// the bond and mints 1:1 HNDb to the actor.
    function ownerMint(uint8 actorIdx, uint256 amount) public {
        address actor = actors[actorIdx % 8];
        uint256 backing = hnd.balanceOf(address(this));
        if (amount > backing) amount = backing;
        if (amount == 0) return;
        bond.mint(actor, amount);
    }

    /// @notice user-side bond burn: actor's HNDb is burned and its HND backing
    /// returns to the owner (handler).
    function actorBurn(uint8 actorIdx, uint256 amount) public {
        address actor = actors[actorIdx % 8];
        uint256 bal = bond.balanceOf(actor);
        if (amount > bal) amount = bal;
        if (amount == 0) return;
        VM.startPrank(actor);
        bond.burn(amount);
        VM.stopPrank();
    }

    /// @notice user-side bond redemption: actor's entire HNDb is burned and
    /// the HND backing is locked into the voting escrow on their behalf.
    function actorRedeem(uint8 actorIdx) public {
        address actor = actors[actorIdx % 8];
        if (bond.balanceOf(actor) == 0) return;
        VM.startPrank(actor);
        bond.redeem();
        VM.stopPrank();
    }

    /// @notice move time forward so escrow lock expiries change. Capped so the
    /// mock's int128 lock amounts can never approach their bound.
    function warp(uint256 seconds_) public {
        VM.warp(block.timestamp + (seconds_ % (200 * 7 * 86400)));
    }

    // ============================================================
    //  Invariant checks (called from the test contract)
    // ============================================================

    /// @notice every outstanding HNDb is backed 1:1 by HND sitting in the bond
    /// contract: `hnd.balanceOf(bond) == bond.totalSupply()`.
    function checkBacking() external view returns (bool) {
        return hnd.balanceOf(address(bond)) == bond.totalSupply();
    }

    /// @notice HNDb ERC20 exactness: totalSupply == sum of all holder balances.
    function checkBondSupply() external view returns (bool) {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += bond.balanceOf(actors[i]);
        }
        return sum == bond.totalSupply();
    }

    /// @notice HND is never created or destroyed by the system: owner/handler +
    /// bond + escrow + actors == the initial mint.
    function checkHndConservation() external view returns (bool) {
        uint256 sum = hnd.balanceOf(address(this));
        sum += hnd.balanceOf(address(bond));
        sum += hnd.balanceOf(address(escrow));
        for (uint256 i = 0; i < actors.length; i++) {
            sum += hnd.balanceOf(actors[i]);
        }
        return sum == initialHnd;
    }
}
