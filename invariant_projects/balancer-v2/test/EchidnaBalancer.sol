// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "./BalancerHandler.sol";

/// Echidna entry point for the Balancer v2 Vault invariant harness.
///
/// Composition (rather than inheritance) keeps the fuzz-target ABI explicit so
/// the filterFunctions whitelist matches cleanly — the same pattern as the
/// morpho-blue, rocket-pool, kpk, hundred-bond, compound-v2 and credit-guild
/// wrappers.
contract EchidnaBalancer {
    BalancerHandler public h;

    constructor() {
        h = new BalancerHandler();
    }

    // ====== Forwarded fuzz actions ======
    // Index args are mod-reduced here because the handler silently `return`s
    // on out-of-range indices (poolIdx>=2, actorIdx>=8, tokenIdx>=3), which
    // would waste ~99% of echidna's raw uint8 calldata on no-ops. The mod is
    // semantics-preserving: the handler itself indexes the same arrays.

    function swapGivenIn(
        uint8 poolIdx,
        uint8 actorIdx,
        uint8 tokenInIdx,
        uint8 tokenOutIdx,
        uint256 amount
    ) external {
        h.swapGivenIn(poolIdx % 2, actorIdx % 8, tokenInIdx % 3, tokenOutIdx % 3, amount);
    }

    function swapGivenOut(
        uint8 poolIdx,
        uint8 actorIdx,
        uint8 tokenInIdx,
        uint8 tokenOutIdx,
        uint256 amount
    ) external {
        h.swapGivenOut(poolIdx % 2, actorIdx % 8, tokenInIdx % 3, tokenOutIdx % 3, amount);
    }

    function joinPool(uint8 poolIdx, uint8 actorIdx, uint8 tokenIdx, uint256 amount) external {
        h.joinPool(poolIdx % 2, actorIdx % 8, tokenIdx % 3, amount);
    }

    function exitPool(uint8 poolIdx, uint8 actorIdx, uint8 tokenIdx, uint256 amount) external {
        h.exitPool(poolIdx % 2, actorIdx % 8, tokenIdx % 3, amount);
    }

    function flashLoan(uint8 actorIdx, uint8 tokenIdx, uint256 amount, uint8 mode) external {
        h.flashLoan(actorIdx % 8, tokenIdx % 3, amount, mode % 4);
    }

    function depositInternal(uint8 actorIdx, uint8 tokenIdx, uint256 amount) external {
        h.depositInternal(actorIdx % 8, tokenIdx % 3, amount);
    }

    function withdrawInternal(uint8 actorIdx, uint8 tokenIdx, uint256 amount) external {
        h.withdrawInternal(actorIdx % 8, tokenIdx % 3, amount);
    }

    function transferInternal(uint8 fromIdx, uint8 toIdx, uint8 tokenIdx, uint256 amount) external {
        h.transferInternal(fromIdx % 8, toIdx % 8, tokenIdx % 3, amount);
    }

    // ====== Properties ======

    function echidna_token_conservation_0() public view returns (bool) {
        return h.checkTokenConservation(0);
    }

    function echidna_token_conservation_1() public view returns (bool) {
        return h.checkTokenConservation(1);
    }

    function echidna_token_conservation_2() public view returns (bool) {
        return h.checkTokenConservation(2);
    }

    function echidna_vault_ledger_0() public view returns (bool) {
        return h.checkVaultLedger(0);
    }

    function echidna_vault_ledger_1() public view returns (bool) {
        return h.checkVaultLedger(1);
    }

    function echidna_vault_ledger_2() public view returns (bool) {
        return h.checkVaultLedger(2);
    }

    function echidna_pool_shares_0() public view returns (bool) {
        return h.checkPoolShares(0);
    }

    function echidna_pool_shares_1() public view returns (bool) {
        return h.checkPoolShares(1);
    }
}
