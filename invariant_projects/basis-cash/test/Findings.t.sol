// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "../src/contracts/Cash.sol";
import "../src/contracts/Share.sol";
import "../src/contracts/Boardroom.sol";

interface VmF {
    function startPrank(address) external;
    function stopPrank() external;
    function roll(uint256) external;
    function warp(uint256) external;
}

// CONFIRMED Phase 3 finding: Boardroom withdraw-retroactive reward inflation.
contract Findings {
    VmF internal constant VM = VmF(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    Cash public cash;
    Share public share;
    Boardroom public boardroom;

    address internal A = 0xAA00000000000000000000000000000000000001;
    address internal B = 0xBb00000000000000000000000000000000000001;

    function setUp() public {
        cash = new Cash();
        share = new Share();
        boardroom = new Boardroom(IERC20(address(cash)), IERC20(address(share)));
        share.mint(A, 1000 ether);
        share.mint(B, 1000 ether);
    }

    // Phantom/retroactive reward inflation on withdrawal:
    // 1) A and B each stake 100 shares.
    // 2) Treasury allocates 100 cash  (snapshot: reward=100, totalShares=200).
    // 3) B exits fully. B's claim at exit time = 100*100/200 = 50 (paid).
    //    Withdraw also rewrites the last snapshot totalShares 200 -> 100.
    // 4) A's pending earnings now = 100*100/100 = 100, but the boardroom only
    //    holds 50 cash. A's claim (and any later withdraw) must revert.
    function test_phantomRewardOnWithdraw() public {
        VM.startPrank(A);
        share.approve(address(boardroom), 100 ether);
        boardroom.stake(100 ether);
        VM.stopPrank();
        VM.roll(block.number + 1); VM.warp(block.timestamp + 12);

        VM.startPrank(B);
        share.approve(address(boardroom), 100 ether);
        boardroom.stake(100 ether);
        VM.stopPrank();
        VM.roll(block.number + 1); VM.warp(block.timestamp + 12);

        cash.mint(address(this), 100 ether);
        cash.approve(address(boardroom), 100 ether);
        boardroom.allocateSeigniorage(100 ether);
        VM.roll(block.number + 1); VM.warp(block.timestamp + 12);

        VM.startPrank(B);
        boardroom.withdraw(100 ether);
        VM.stopPrank();
        VM.roll(block.number + 1); VM.warp(block.timestamp + 12);

        // A's pending (100) exceeds the cash the boardroom holds (50).
        require(boardroom.getCashEarningsOf(A) > cash.balanceOf(address(boardroom)),
            "expected inflated pending to exceed held cash");
    }
}
