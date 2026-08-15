// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "../src/contracts/Cash.sol";
import "../src/contracts/Share.sol";
import "../src/contracts/Boardroom.sol";

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function roll(uint256) external;
    function warp(uint256) external;
}

// Handler is the OPERATOR of cash, share, and boardroom.
// All boardroom reward allocations flow through the handler, mirroring how
// Treasury pushes seigniorage to the Boardroom in the real protocol.
contract BasisCashHandler {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    Cash public cash;
    Share public share;
    Boardroom public boardroom;

    address[8] public actors;

    uint256 public constant SHARE_MINT = 100_000 ether;
    uint256 public allocatedToBoardroom;      // total cash pushed into boardroom
    uint256 public totalClaimedByActors;      // cash actually claimed by actors

    constructor() public {
        setUp(
            0x1111000000000000000000000000000000000001,
            0x1111000000000000000000000000000000000002,
            0x1111000000000000000000000000000000000003,
            0x1111000000000000000000000000000000000004,
            0x1111000000000000000000000000000000000005,
            0x1111000000000000000000000000000000000006,
            0x1111000000000000000000000000000000000007,
            0x1111000000000000000000000000000000000008
        );
    }

    function setUp(
        address a1, address a2, address a3, address a4,
        address a5, address a6, address a7, address a8
    ) internal {
        actors[0] = a1; actors[1] = a2; actors[2] = a3; actors[3] = a4;
        actors[4] = a5; actors[5] = a6; actors[6] = a7; actors[7] = a8;

        cash      = new Cash();
        share     = new Share();
        boardroom = new Boardroom(IERC20(address(cash)), IERC20(address(share)));

        for (uint256 i = 0; i < actors.length; i++) {
            if (actors[i] == address(0)) continue;
            share.mint(actors[i], SHARE_MINT);
        }
    }

    // ====== Boardroom actions ======

    function actorStake(uint8 actorIdx, uint256 amount) public {
        address actor = actors[actorIdx % 8];
        if (actor == address(0) || amount == 0) return;
        if (amount > share.balanceOf(actor)) return;
        VM.startPrank(actor);
        share.approve(address(boardroom), amount);
        boardroom.stake(amount);
        VM.stopPrank();
        VM.roll(block.number + 1);
        VM.warp(block.timestamp + 12);
    }

    function actorWithdraw(uint8 actorIdx, uint256 amount) public {
        address actor = actors[actorIdx % 8];
        if (actor == address(0) || amount == 0) return;
        uint256 staked = boardroom.getShareOf(actor);
        if (staked == 0 || amount > staked) return;
        uint256 before = cash.balanceOf(address(boardroom));
        VM.startPrank(actor);
        boardroom.withdraw(amount);
        VM.stopPrank();
        uint256 balanceAfter = cash.balanceOf(address(boardroom));
        if (balanceAfter < before) totalClaimedByActors += before - balanceAfter;
        VM.roll(block.number + 1);
        VM.warp(block.timestamp + 12);
    }

    function actorClaim(uint8 actorIdx) public {
        address actor = actors[actorIdx % 8];
        if (actor == address(0)) return;
        if (boardroom.getShareOf(actor) == 0) return;
        uint256 before = cash.balanceOf(address(boardroom));
        VM.startPrank(actor);
        boardroom.claimDividends();
        VM.stopPrank();
        uint256 balanceAfter = cash.balanceOf(address(boardroom));
        if (balanceAfter < before) totalClaimedByActors += before - balanceAfter;
        VM.roll(block.number + 1);
        VM.warp(block.timestamp + 12);
    }

    function allocateSeigniorage(uint256 amount) public {
        if (amount == 0) return;
        if (amount > 10_000 ether) return;
        // Sane-treasury guard: never allocate into a boardroom with zero
        // directors. The unprotected zero-totalShares path (genesis/snapshot
        // div-by-zero bricking getCashEarningsOf) is documented separately in
        // the scenario test; guarding it here lets the fuzzer explore the
        // reward-accounting invariants without every run reverting.
        if (boardroom.totalShare() == 0) return;
        cash.mint(address(this), amount);
        cash.approve(address(boardroom), amount);
        boardroom.allocateSeigniorage(amount);
        allocatedToBoardroom += amount;
        VM.roll(block.number + 1);
        VM.warp(block.timestamp + 12);
    }

    function warpDays(uint256 numDays) public {
        if (numDays == 0 || numDays > 365) return;
        VM.warp(block.timestamp + numDays * 1 days);
    }

    // ====== Invariant checks (kept in the handler: running the comparison
    // from the test contract tripped a solc 0.6.12 / Foundry 1.7.1 prober
    // bug that reported valid checks as InvalidFEOpcode) ======

    // Conservation: pending claims + already-claimed cash must never exceed
    // total seigniorage allocated to the boardroom. Violation = the boardroom
    // has promised more rewards than the cash it holds (phantom rewards).
    function checkEarningsNeverExceedAllocated() public view returns (bool) {
        uint256 pending = sumPendingEarnings();
        return pending + totalClaimedByActors <= allocatedToBoardroom;
    }

    // No reward can be claimed by an actor who never staked (zero shares).
    function checkNoRewardWithoutStake() public view returns (bool) {
        for (uint256 i = 0; i < actors.length; i++) {
            if (actors[i] == address(0)) continue;
            if (boardroom.getShareOf(actors[i]) == 0) {
                if (boardroom.getCashEarningsOf(actors[i]) != 0) return false;
            }
        }
        return true;
    }

    // Share tokens are conserved: actors + boardroom == total supply.
    function checkShareBooksBalance() public view returns (bool) {
        uint256 total = share.balanceOf(address(boardroom));
        for (uint256 i = 0; i < actors.length; i++) {
            if (actors[i] == address(0)) continue;
            total += share.balanceOf(actors[i]);
        }
        // Supply is 8 * SHARE_MINT and no handler action mints or burns share.
        return total == 8 * SHARE_MINT;
    }

    // ====== View helpers ======

    // Sum of ALL currently-claimable cash earnings across the 8 actors.
    function sumPendingEarnings() public view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            if (actors[i] == address(0)) continue;
            total += boardroom.getCashEarningsOf(actors[i]);
        }
    }
}
