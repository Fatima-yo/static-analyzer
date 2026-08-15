// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./MonolithHandler.sol";

/// @notice Invariant suite for monolith-market's Lender/Vault. The fuzzer
/// drives only the handler (raw StdInvariant ABI, no forge-std dependency)
/// from the 6 actor addresses. All invariants are exact ledger identities:
/// any mint/borrow/repay/redemption/liquidation/write-off double-spend or
/// share-bookkeeping bug in the Coin ledger, the debt-share pools, the vault
/// share book or the reserve pulls breaks at least one of them.
contract MonolithInvariants {
    MonolithHandler internal h;

    function getH() external view returns (MonolithHandler) {
        return h;
    }

    address[] internal _targetedContracts;
    address[] internal _targetedSenders;

    constructor() {
        h = new MonolithHandler();
        _targetedContracts.push(address(h));
        for (uint256 i = 0; i < 6; ++i) {
            _targetedSenders.push(h.actors(i));
        }
    }

    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    function targetSelectors() public view returns (FuzzSelector[] memory targetedSelectors) {
        targetedSelectors = new FuzzSelector[](1);
        targetedSelectors[0].addr = address(h);
        targetedSelectors[0].selectors = new bytes4[](19);
        targetedSelectors[0].selectors[0] = h.adjustDeposit.selector;
        targetedSelectors[0].selectors[1] = h.adjustBorrow.selector;
        targetedSelectors[0].selectors[2] = h.adjustRepay.selector;
        targetedSelectors[0].selectors[3] = h.adjustWithdraw.selector;
        targetedSelectors[0].selectors[4] = h.combinedBorrow.selector;
        targetedSelectors[0].selectors[5] = h.optInRedemption.selector;
        targetedSelectors[0].selectors[6] = h.optOutRedemption.selector;
        targetedSelectors[0].selectors[7] = h.liquidate.selector;
        targetedSelectors[0].selectors[8] = h.redeem.selector;
        targetedSelectors[0].selectors[9] = h.attemptWriteOff.selector;
        targetedSelectors[0].selectors[10] = h.vaultDeposit.selector;
        targetedSelectors[0].selectors[11] = h.vaultMint.selector;
        targetedSelectors[0].selectors[12] = h.vaultWithdraw.selector;
        targetedSelectors[0].selectors[13] = h.vaultRedeem.selector;
        targetedSelectors[0].selectors[14] = h.shockPrice.selector;
        targetedSelectors[0].selectors[15] = h.warp.selector;
        targetedSelectors[0].selectors[16] = h.operatorSetter.selector;
        targetedSelectors[0].selectors[17] = h.pullLocalReserves.selector;
        targetedSelectors[0].selectors[18] = h.pullGlobalReserves.selector;
    }

    function targetContracts() public view returns (address[] memory) {
        return _targetedContracts;
    }

    function targetSenders() public view returns (address[] memory) {
        return _targetedSenders;
    }

    /// The Coin ledger is exact: supply == totalFreeDebt + totalPaidDebt -
    /// accruedLocalReserves - accruedGlobalReserves. Every borrow/repay/redeem/
    /// liquidate/write-off/interest/pull moves both sides by the same amount,
    /// so a double mint, a skipped burn or a share-book mismatch breaks this.
    function invariant_coinLedger() public view {
        require(h.checkCoinLedger(), "VIOLATION: Coin ledger out of balance");
    }

    /// The paid-debt share pool is conserved exactly (the redemption index only
    /// rewrites free-debt shares, never paid shares).
    function invariant_paidSharesConserved() public view {
        require(h.checkPaidSharesConserved(), "VIOLATION: paid debt share book not conserved");
    }

    /// The vault share book is exact: only the MIN_SHARES dead shares plus the
    /// tracked actors ever hold vault shares.
    function invariant_vaultSharesConserved() public view {
        require(h.checkVaultSharesConserved(), "VIOLATION: vault share book not conserved");
    }

    /// Vault shares are always covered by assets (no ERC4626 share inflation).
    function invariant_vaultCovered() public view {
        if (!h.checkVaultCovered()) {
            revert(
                string(
                    abi.encodePacked(
                        "VIOLATION: vault shares not covered; assets=",
                        h.uint2str(h.vault().totalAssets()),
                        " supply=",
                        h.uint2str(h.vault().totalSupply())
                    )
                )
            );
        }
    }

    /// The lender never retains Coin: repay/redeem/liquidate burn the Coin they
    /// receive in the same call.
    function invariant_lenderHoldsNoCoin() public view {
        require(h.checkLenderHoldsNoCoin(), "VIOLATION: lender retained Coin");
    }
}
