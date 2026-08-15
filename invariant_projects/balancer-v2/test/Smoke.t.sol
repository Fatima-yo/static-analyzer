// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "./BalancerHandler.sol";

/// @notice Round-trip smoke tests over the Balancer V2 harness. No forge-std
/// dependency, matching the compound-v2 / hundred-bond playbook. These pin the
/// accounting invariants (conservation, vault ledger, pool shares) against
/// deterministic join/exit/swap/flash-loan/internal-balance flows before the
/// fuzzer is let loose.
contract BalancerSmoke {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    BalancerHandler internal h;

    constructor() public {
        h = new BalancerHandler();
    }

    function _actor(uint8 i) internal view returns (address) {
        return address(h.actors(i % 8));
    }

    function _seedPool0BothTokens() internal {
        // give the pool ~1000 of each token so swaps and flash loans have room
        h.joinPool(0, 0, 0, 1000 ether);
        h.joinPool(0, 0, 1, 1000 ether);
    }

    function test_join_mints_shares_and_moves_tokens() public {
        h.joinPool(0, 0, 0, 100 ether);

        require(h.pools(0).balanceOf(_actor(0)) == 100 ether, "wrong shares");
        require(h.pools(0).totalSupply() == 100 ether, "wrong supply");
        require(h.tokens(0).balanceOf(_actor(0)) == 100_000 ether - 100 ether, "tokens not pulled");
        require(h.tokens(0).balanceOf(address(h.vault())) == 100 ether, "vault not credited");

        require(h.checkTokenConservation(0), "conservation broken");
        require(h.checkVaultLedger(0), "ledger broken");
        require(h.checkPoolShares(0), "shares broken");
    }

    function test_exit_roundtrip_returns_tokens() public {
        h.joinPool(0, 0, 0, 100 ether);
        h.exitPool(0, 0, 0, 100 ether);

        require(h.pools(0).balanceOf(_actor(0)) == 0, "shares not burned");
        require(h.pools(0).totalSupply() == 0, "supply not zero");
        require(h.tokens(0).balanceOf(_actor(0)) == 100_000 ether, "tokens not returned");
        require(h.tokens(0).balanceOf(address(h.vault())) == 0, "vault not emptied");

        require(h.checkTokenConservation(0), "conservation broken");
        require(h.checkVaultLedger(0), "ledger broken");
        require(h.checkPoolShares(0), "shares broken");
    }

    function test_swap_given_in_breaks_even() public {
        _seedPool0BothTokens();

        h.swapGivenIn(0, 0, 0, 1, 100 ether);

        // constant product k must not have moved (no-fee pool)
        uint256 kBefore = 1000 ether * 1000 ether;
        (, uint256[] memory balances, ) = h.vault().getPoolTokens(h.pools(0).poolId());
        uint256 kAfter = balances[0] * balances[1];
        require(kAfter >= kBefore, "k decreased");
        require(kAfter < kBefore + kBefore / 1000, "k jumped");

        require(h.checkTokenConservation(0), "conservation broken");
        require(h.checkTokenConservation(1), "conservation broken");
        require(h.checkVaultLedger(0), "ledger broken");
        require(h.checkVaultLedger(1), "ledger broken");
        require(h.checkPoolShares(0), "shares broken");
    }

    function test_flashLoan_repay_is_neutral() public {
        _seedPool0BothTokens();
        uint256 vaultBalBefore = h.tokens(0).balanceOf(address(h.vault()));

        h.flashLoan(0, 0, 100 ether, 0);

        require(h.tokens(0).balanceOf(address(h.vault())) == vaultBalBefore, "vault balance moved");
        require(h.tokens(0).balanceOf(address(h.loanRecipients(0))) == 0, "recipient kept tokens");

        require(h.checkTokenConservation(0), "conservation broken");
        require(h.checkVaultLedger(0), "ledger broken");
    }

    function test_flashLoan_no_repay_reverts() public {
        _seedPool0BothTokens();
        uint256 vaultBalBefore = h.tokens(0).balanceOf(address(h.vault()));

        VM.expectRevert(bytes("BAL#515"));
        h.flashLoan(0, 0, 100 ether, 1);

        require(h.tokens(0).balanceOf(address(h.vault())) == vaultBalBefore, "vault lost tokens");
        require(h.checkTokenConservation(0), "conservation broken");
        require(h.checkVaultLedger(0), "ledger broken");
    }

    function test_flashLoan_underpay_reverts() public {
        _seedPool0BothTokens();
        uint256 vaultBalBefore = h.tokens(0).balanceOf(address(h.vault()));

        VM.expectRevert(bytes("BAL#515"));
        h.flashLoan(0, 0, 100 ether, 2);

        require(h.tokens(0).balanceOf(address(h.vault())) == vaultBalBefore, "vault lost tokens");
        require(h.checkTokenConservation(0), "conservation broken");
        require(h.checkVaultLedger(0), "ledger broken");
    }

    function test_internal_deposit_withdraw_roundtrip() public {
        h.depositInternal(0, 0, 50 ether);
        require(h.tokens(0).balanceOf(address(h.vault())) == 50 ether, "vault not credited");
        require(h.checkVaultLedger(0), "ledger broken");

        h.withdrawInternal(0, 0, 50 ether);
        require(h.tokens(0).balanceOf(address(h.vault())) == 0, "vault not emptied");
        require(h.tokens(0).balanceOf(_actor(0)) == 100_000 ether, "tokens not returned");
        require(h.checkTokenConservation(0), "conservation broken");
        require(h.checkVaultLedger(0), "ledger broken");
    }

    function test_internal_transfer_moves_internal_balance() public {
        h.depositInternal(0, 0, 50 ether);
        h.transferInternal(0, 1, 0, 20 ether);

        require(h.checkVaultLedger(0), "ledger broken");
        require(h.checkTokenConservation(0), "conservation broken");

        h.withdrawInternal(1, 0, 20 ether);
        require(h.tokens(0).balanceOf(_actor(1)) == 100_000 ether + 20 ether, "wrong recipient");
        require(h.checkVaultLedger(0), "ledger broken");
        require(h.checkTokenConservation(0), "conservation broken");
    }
}
