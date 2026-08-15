// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./MorphoHandler.sol";

/// @notice Invariant suite for morpho-blue's Morpho. The fuzzer drives only the
/// handler (raw StdInvariant ABI, no forge-std dependency) from the 8 actor
/// addresses. All invariants are exact ledger identities: any mint/burn/transfer
/// accounting bug in supply, borrow, collateral, liquidation or interest/fee
/// accrual breaks at least one of them.
contract MorphoInvariants {
    MorphoHandler internal h;

    function getH() external view returns (MorphoHandler) {
        return h;
    }

    address[] internal _targetedContracts;
    address[] internal _targetedSenders;

    constructor() {
        h = new MorphoHandler();
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
        targetedSelectors[0].selectors = new bytes4[](12);
        targetedSelectors[0].selectors[0] = h.supply.selector;
        targetedSelectors[0].selectors[1] = h.supplyCollateral.selector;
        targetedSelectors[0].selectors[2] = h.borrow.selector;
        targetedSelectors[0].selectors[3] = h.withdraw.selector;
        targetedSelectors[0].selectors[4] = h.withdrawCollateral.selector;
        targetedSelectors[0].selectors[5] = h.repay.selector;
        targetedSelectors[0].selectors[6] = h.liquidate.selector;
        targetedSelectors[0].selectors[7] = h.accrue.selector;
        targetedSelectors[0].selectors[8] = h.warp.selector;
        targetedSelectors[0].selectors[9] = h.setFee.selector;
        targetedSelectors[0].selectors[10] = h.setFeeRecipient.selector;
        targetedSelectors[0].selectors[11] = h.setOwner.selector;
    }

    function targetContracts() public view returns (address[] memory) {
        return _targetedContracts;
    }

    function targetSenders() public view returns (address[] memory) {
        return _targetedSenders;
    }

    /// Every supply share on the books lives in a tracked position (market A).
    function invariant_supplySharesConserved_m0() public view {
        require(h.checkSupplySharesConserved(0), "VIOLATION: supply shares not conserved (m0)");
    }

    /// Every supply share on the books lives in a tracked position (market B).
    function invariant_supplySharesConserved_m1() public view {
        require(h.checkSupplySharesConserved(1), "VIOLATION: supply shares not conserved (m1)");
    }

    /// Every borrow share on the books lives in a tracked position (market A).
    function invariant_borrowSharesConserved_m0() public view {
        require(h.checkBorrowSharesConserved(0), "VIOLATION: borrow shares not conserved (m0)");
    }

    /// Every borrow share on the books lives in a tracked position (market B).
    function invariant_borrowSharesConserved_m1() public view {
        require(h.checkBorrowSharesConserved(1), "VIOLATION: borrow shares not conserved (m1)");
    }

    /// Morpho's USDC balance is never below the USDC idle pool (m0 supply minus
    /// borrow) plus the USDC collateral held for m1 borrowers. No value is
    /// destroyed anywhere in the ledger (the cumulative +1-wei repay rounding
    /// dust can only ever push the balance above the book).
    function invariant_usdcBalanceConserved() public view {
        require(h.checkTokenBalance(0), "VIOLATION: USDC balance-sheet identity broken");
    }

    /// Morpho's WETH balance is never below the WETH idle pool (m1 supply minus
    /// borrow) plus the WETH collateral held for m0 borrowers.
    function invariant_wethBalanceConserved() public view {
        require(h.checkTokenBalance(1), "VIOLATION: WETH balance-sheet identity broken");
    }

    /// Every USDC-token action moves the physical balance in lockstep with the
    /// book (or exceeds it by exactly the protocol's 1-wei repay rounding).
    /// No value is created: any mint-without-transfer, borrow-without-transfer
    /// or flash-loan theft makes the residual leave {0, 1}.
    function invariant_usdcLedgerResidual() public view {
        require(h.checkUsdcResidual(), "VIOLATION: USDC ledger residual outside {0,1}");
    }

    /// Every WETH-token action moves the physical balance in lockstep with the
    /// book (or exceeds it by exactly the protocol's 1-wei repay rounding).
    function invariant_wethLedgerResidual() public view {
        require(h.checkWethResidual(), "VIOLATION: WETH ledger residual outside {0,1}");
    }

    /// A market's supply book can never be under water relative to its borrow
    /// book (market A).
    function invariant_marketSolvent_m0() public view {
        require(h.checkMarketSolvent(0), "VIOLATION: market A insolvent");
    }

    /// A market's supply book can never be under water relative to its borrow
    /// book (market B).
    function invariant_marketSolvent_m1() public view {
        require(h.checkMarketSolvent(1), "VIOLATION: market B insolvent");
    }
}
