// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./CometHandler.sol";

/// @notice Invariant suite for compound-v3's Comet. The fuzzer drives only the
/// handler (raw StdInvariant ABI, no forge-std dependency) from the 8 actor
/// addresses. All invariants are exact ledger identities: any mint/borrow/
/// double-spend/absorb accounting bug in supply, withdraw, transfer, borrow,
/// repay or absorption breaks at least one of them.
contract CometInvariants {
    CometHandler internal h;

    function getH() external view returns (CometHandler) {
        return h;
    }

    address[] internal _targetedContracts;
    address[] internal _targetedSenders;

    constructor() {
        h = new CometHandler();
        _targetedContracts.push(address(h));
        for (uint256 i = 0; i < 8; ++i) {
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
        targetedSelectors[0].selectors = new bytes4[](7);
        targetedSelectors[0].selectors[0] = h.supply.selector;
        targetedSelectors[0].selectors[1] = h.withdraw.selector;
        targetedSelectors[0].selectors[2] = h.transfer.selector;
        targetedSelectors[0].selectors[3] = h.absorb.selector;
        targetedSelectors[0].selectors[4] = h.buyCollateral.selector;
        targetedSelectors[0].selectors[5] = h.pause.selector;
        targetedSelectors[0].selectors[6] = h.warp.selector;
    }

    function targetContracts() public view returns (address[] memory) {
        return _targetedContracts;
    }

    function targetSenders() public view returns (address[] memory) {
        return _targetedSenders;
    }

    /// The base principal book is exact: sum(actor positive principal) ==
    /// totalSupplyBase and sum(actor |negative principal|) == totalBorrowBase.
    /// Comet stores principals directly (no share conversion), so this identity
    /// holds exactly and catches any mint/borrow/double-spend corruption.
    function invariant_baseBookConserved() public view {
        require(h.checkBaseBookConserved(), "VIOLATION: base principal book not conserved");
    }

    /// Every WETH collateral unit lives in a tracked actor account.
    function invariant_collateralBookWeth() public view {
        require(h.checkCollateralBookConserved(0), "VIOLATION: WETH collateral book not conserved");
    }

    /// Every WBTC collateral unit lives in a tracked actor account.
    function invariant_collateralBookWbtc() public view {
        require(h.checkCollateralBookConserved(1), "VIOLATION: WBTC collateral book not conserved");
    }

    /// The protocol ledger never loses value outside of absorbed bad debt:
    /// reserves (= balance - presentSupply + presentBorrow) + absorbedBadDebt
    /// is always >= 0. No supply/withdraw/borrow/repay/transfer path may drain
    /// value out of the protocol.
    function invariant_baseNoLeak() public view {
        require(h.checkBaseNoLeak(), "VIOLATION: base value leaked out of the protocol");
    }

    /// Every non-absorb action leaves reserves non-decreasing up to one base
    /// unit of rounding dust (principalValue/presentValue floor round-trip);
    /// anything below -DUST is a real value-leak path.
    function invariant_lastResidual() public view {
        if (!h.checkLastResidual()) {
            revert(
                string(
                    abi.encodePacked(
                        "VIOLATION: non-absorb action shrank reserves; delta=",
                        h.uint2str(uint256(int256(h.lastDelta())))
                    )
                )
            );
        }
    }

    /// Absorption never writes off more debt than the account owed, up to one
    /// base unit of index/PV rounding dust.
    function invariant_absorbAccounting() public view {
        if (!h.checkAbsorbAccounting()) {
            revert(
                string(
                    abi.encodePacked(
                        "VIOLATION: absorb debt-bound broken; delta=",
                        h.uint2str(uint256(int256(h.lastDelta()))),
                        " bound=",
                        h.uint2str(h.lastBound())
                    )
                )
            );
        }
    }

    /// Market solvency in present value (supply >= borrow).
    function invariant_marketSolvent() public view {
        require(h.checkMarketSolvent(), "VIOLATION: market insolvent");
    }
}
