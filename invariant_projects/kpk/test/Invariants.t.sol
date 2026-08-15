// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./KpkHandler.sol";

/// @notice Invariant suite for kpk's KpkShares fund vault. The fuzzer drives
/// only the handler (raw StdInvariant ABI, no forge-std dependency) from the
/// 6 actor addresses. Both invariants are exact ledger identities — any
/// double mint, skipped burn, mistargeted transfer or escrow-book
/// desynchronization in the share token or the per-asset subscription escrow
/// breaks one of them.
contract KpkInvariants {
    KpkHandler internal h;

    function getH() external view returns (KpkHandler) {
        return h;
    }

    address[] internal _targetedContracts;
    address[] internal _targetedSenders;

    constructor() {
        h = new KpkHandler();
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
        targetedSelectors[0].selectors = new bytes4[](9);
        targetedSelectors[0].selectors[0] = h.requestSubscriptionAction.selector;
        targetedSelectors[0].selectors[1] = h.cancelSubscriptionAction.selector;
        targetedSelectors[0].selectors[2] = h.requestRedemptionAction.selector;
        targetedSelectors[0].selectors[3] = h.cancelRedemptionAction.selector;
        targetedSelectors[0].selectors[4] = h.processAction.selector;
        targetedSelectors[0].selectors[5] = h.recoverAction.selector;
        targetedSelectors[0].selectors[6] = h.updateAssetAction.selector;
        targetedSelectors[0].selectors[7] = h.setterAction.selector;
        targetedSelectors[0].selectors[8] = h.warp.selector;
    }

    function targetContracts() public view returns (address[] memory) {
        return _targetedContracts;
    }

    function targetSenders() public view returns (address[] memory) {
        return _targetedSenders;
    }

    /// The share token is conserved exactly across subscription minting,
    /// redemption escrow, fee mints to the fee receiver and burns on
    /// redemption approval.
    function invariant_shareBook() public view {
        require(h.checkShareBook(), "VIOLATION: share book out of balance");
    }

    /// The per-asset subscription escrow is exact: every asset unit sitting on
    /// the vault is matched by a pending-subscription liability.
    function invariant_assetEscrow() public view {
        require(h.checkAssetEscrow(), "VIOLATION: asset escrow out of balance");
    }
}
