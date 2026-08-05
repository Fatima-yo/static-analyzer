// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import { AddressesProvider } from "../src/ionic/AddressesProvider.sol";
import "./IonicHandler.sol";

/// @notice Directed smoke tests for the Ionic harness: end-to-end market flows
/// plus direct confirmation of the run3 MEDIUM findings on AddressesProvider
/// (missing zero-address checks in the eight admin setters).
contract IonicSmoke {
    // End-to-end market flows ----------------------------------------------

    function test_liquidate_endToEnd() public {
        IonicHandler h = new IonicHandler();
        h.actorMint(0, 0, 1000e6); // actor0 supplies USDC (collateral)
        h.actorMint(1, 1, 1000e18); // actor1 supplies WETH (liquidity)
        h.actorBorrow(0, 1, 1e18); // actor0 borrows WETH
        h.actorLiquidate(1, 0, 1, 0, 1e18); // actor1 liquidates actor0
        require(h.checkCtokenConservation(), "cToken leak");
        require(h.checkUnderlyingConservation(), "underlying leak");
        require(h.checkBorrowSum(), "borrow ledger leak");
    }

    function test_accrualConservation() public {
        IonicHandler h = new IonicHandler();
        h.actorMint(0, 0, 1000e6);
        h.actorMint(0, 1, 100e18);
        h.actorBorrow(0, 1, 10e18);
        h.warpBlocks(1000); // let interest accrue over many blocks
        h.actorRepay(0, 1, 10e18); // partial repayment (interest stays)
        require(h.checkCtokenConservation(), "cToken leak");
        require(h.checkUnderlyingConservation(), "underlying leak");
        require(h.checkBorrowSum(), "borrow ledger leak");
    }

    function test_transferConvervation() public {
        IonicHandler h = new IonicHandler();
        h.actorMint(0, 0, 1000e6);
        h.actorMint(1, 0, 1000e6);
        h.actorTransfer(0, 1, 0, 500e6);
        h.actorTransfer(1, 2, 0, 200e6);
        require(h.checkCtokenConservation(), "cToken leak");
        require(h.checkUnderlyingConservation(), "underlying leak");
    }

    function test_repayBehalf() public {
        IonicHandler h = new IonicHandler();
        h.actorMint(0, 0, 1000e6);
        h.actorMint(0, 1, 1000e18);
        h.actorMint(1, 1, 1000e18);
        h.actorBorrow(0, 1, 50e18);
        h.actorRepayBehalf(1, 0, 1, 30e18);
        require(h.checkCtokenConservation(), "cToken leak");
        require(h.checkUnderlyingConservation(), "underlying leak");
        require(h.checkBorrowSum(), "borrow ledger leak");
    }

    // run3 findings: missing zero-address checks ---------------------------

    function test_setAddress_zeroAccepted() public {
        AddressesProvider ap = new AddressesProvider();
        ap.initialize(address(this));
        ap.setAddress("PoolLens", address(0)); // must NOT revert
    }

    function test_setFlywheelRewards_zeroAccepted() public {
        AddressesProvider ap = new AddressesProvider();
        ap.initialize(address(this));
        ap.setFlywheelRewards(address(0), address(0), ""); // must NOT revert
    }

    function test_setPlugin_zeroAccepted() public {
        AddressesProvider ap = new AddressesProvider();
        ap.initialize(address(this));
        ap.setPlugin(address(0), address(0), ""); // must NOT revert
    }

    function test_setRedemptionStrategy_zeroAccepted() public {
        AddressesProvider ap = new AddressesProvider();
        ap.initialize(address(this));
        ap.setRedemptionStrategy(address(0), address(0), "", address(0)); // must NOT revert
    }

    function test_setFundingStrategy_zeroAccepted() public {
        AddressesProvider ap = new AddressesProvider();
        ap.initialize(address(this));
        ap.setFundingStrategy(address(0), address(0), "", address(0)); // must NOT revert
    }

    function test_setBalancerPool_zeroAccepted() public {
        AddressesProvider ap = new AddressesProvider();
        ap.initialize(address(this));
        ap.setBalancerPoolForTokens(address(0), address(0), address(0)); // must NOT revert
    }

    function test_setPendingOwner_zeroAccepted() public {
        AddressesProvider ap = new AddressesProvider();
        ap.initialize(address(this));
        ap._setPendingOwner(address(0)); // must NOT revert
    }

    function test_transferOwnership_zeroAccepted() public {
        AddressesProvider ap = new AddressesProvider();
        ap.initialize(address(this));
        // SafeOwnableUpgradeable overrides OZ transferOwnership and drops the
        // `newOwner != address(0)` guard, so this must NOT revert.
        ap.transferOwnership(address(0));
    }
}
