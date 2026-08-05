// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./CometHandler.sol";
import {CometMainInterface} from "../src/core/CometMainInterface.sol";

/// @notice Deterministic smoke tests over the compound-v3 Comet harness. No
/// forge-std dependency, matching the balancer-v2 / rocket-pool playbook. Tests
/// drive the real Comet contract directly with pranked actors so guard
/// messages and absorb/bad-debt accounting can be pinned exactly.
contract CometSmokeTests {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    CometHandler internal h;
    CometWithExtendedAssetList internal comet;

    constructor() {
        h = new CometHandler();
        comet = h.comet();
    }

    function _prank(address who) internal {
        VM.startPrank(who);
    }

    function _unprank() internal {
        VM.stopPrank();
    }

    /// supply -> withdraw round-trips exactly (indices start at BASE_INDEX_SCALE,
    /// so the first-conversion principal book is lossless).
    function test_supply_withdraw_roundtrip() public {
        address a = h.actors(0);
        _prank(a);
        comet.supply(address(h.usdc()), 1000e6);
        _unprank();

        require(comet.balanceOf(a) == 1000e6, "balance after supply");
        require(h.checkBaseBookConserved(), "base book broken");
        require(h.checkBaseNoLeak(), "no-leak broken");

        _prank(a);
        comet.withdraw(address(h.usdc()), 1000e6);
        _unprank();

        require(comet.balanceOf(a) == 0, "balance not zeroed");
        require(h.usdc().balanceOf(a) == h.PREFUND_USDC(), "USDC not restored");
        require(h.checkBaseBookConserved() && h.checkBaseNoLeak() && h.checkMarketSolvent(), "ledger broken");
    }

    /// supplyCollateral -> borrow -> repay -> withdrawCollateral round-trips
    /// with only accrued interest lost (none in the same block). A supplier
    /// provides the base liquidity the borrower draws against.
    function test_supply_collateral_borrow_repay_roundtrip() public {
        address supplier = h.actors(0);
        address a = h.actors(1);
        _prank(supplier);
        comet.supply(address(h.usdc()), 10000e6);
        _unprank();

        _prank(a);
        comet.supply(address(h.weth()), 10 ether);
        comet.withdraw(address(h.usdc()), 4000e6);
        _unprank();

        require(comet.borrowBalanceOf(a) == 4000e6, "no borrow position");
        require(comet.isBorrowCollateralized(a), "not collateralized");
        require(h.checkBaseBookConserved() && h.checkCollateralBookConserved(0), "ledger broken");

        _prank(a);
        comet.supply(address(h.usdc()), 4000e6);
        comet.withdraw(address(h.weth()), 10 ether);
        _unprank();

        require(comet.borrowBalanceOf(a) == 0, "debt not repaid");
        require(comet.balanceOf(a) == 0, "base not cleared");
        require(h.weth().balanceOf(a) == h.PREFUND_WETH(), "collateral not restored");
        require(h.checkBaseBookConserved() && h.checkCollateralBookConserved(0) && h.checkMarketSolvent(), "ledger broken");
    }

    /// Transfers of base (borrow-capable) and collateral move between actors.
    function test_transfer_base_and_collateral() public {
        address a = h.actors(2);
        address b = h.actors(3);
        _prank(a);
        comet.supply(address(h.usdc()), 500e6);
        comet.supply(address(h.weth()), 5 ether);
        _unprank();

        _prank(a);
        comet.transfer(b, 200e6);
        _unprank();
        require(comet.balanceOf(b) == 200e6 && comet.balanceOf(a) == 300e6, "base transfer");

        _prank(a);
        comet.transferAsset(b, address(h.weth()), 2 ether);
        _unprank();
        (uint128 cb,) = comet.userCollateral(b, address(h.weth()));
        (uint128 ca,) = comet.userCollateral(a, address(h.weth()));
        require(cb == 2 ether && ca == 3 ether, "collateral transfer");

        require(h.checkBaseBookConserved() && h.checkCollateralBookConserved(0), "ledger broken");
    }

    /// An underwater position (oracle shock) is absorbed: debt written off the
    /// book, collateral seized, reserves drained exactly by the write-off and
    /// fully accounted by absorbedBadDebt. Driven through the handler so the
    /// bad-debt accumulator is updated (handler absorb: idx 10 -> absorber
    /// actor2, victim actor1, WETH oracle shocked to 10% of honest).
    function test_absorb_writes_off_bad_debt() public {
        address supplier = h.actors(0);
        address borrower = h.actors(1);

        _prank(supplier);
        comet.supply(address(h.usdc()), 10000e6);
        _unprank();

        _prank(borrower);
        comet.supply(address(h.weth()), 10 ether);
        comet.withdraw(address(h.usdc()), 4000e6);
        _unprank();

        uint256 debt = comet.borrowBalanceOf(borrower);
        require(debt == 4000e6, "debt");

        int256 reservesBefore = comet.getReserves();
        h.feedWeth().setPrice(h.PRICE_WETH() / 10);
        require(comet.isLiquidatable(borrower), "not liquidatable at shocked price");
        h.feedWeth().setPrice(h.PRICE_WETH());

        h.absorb(10, 9999);

        require(comet.borrowBalanceOf(borrower) == 0, "debt not written off");
        (uint128 cb,) = comet.userCollateral(borrower, address(h.weth()));
        require(cb == 0, "collateral not seized");

        require(h.absorbedBadDebt() >= debt, "bad debt not tracked");
        require(comet.getReserves() == reservesBefore - int256(h.absorbedBadDebt()), "reserves drained by write-off");
        require(h.checkBaseNoLeak(), "no-leak broken");
        require(h.checkBaseBookConserved() && h.checkCollateralBookConserved(0), "ledger broken");
        require(h.checkAbsorbAccounting(), "absorb accounting broken");
    }

    /// Interest accrues on both supply and borrow after time passes. The
    /// borrower draws real debt against a supplier's base liquidity.
    function test_interest_accrual() public {
        address supplier = h.actors(0);
        address a = h.actors(4);
        _prank(supplier);
        comet.supply(address(h.usdc()), 10000e6);
        _unprank();

        _prank(a);
        comet.supply(address(h.weth()), 10 ether);
        comet.withdraw(address(h.usdc()), 4000e6);
        _unprank();

        uint256 supply0 = comet.totalSupply();
        uint256 borrow0 = comet.totalBorrow();
        int256 reserves0 = comet.getReserves();

        h.warp(30 days);

        require(comet.totalBorrow() > borrow0, "borrow interest not accrued");
        require(comet.totalSupply() > supply0, "supply interest not accrued");
        require(comet.getReserves() >= reserves0, "reserves shrank on accrual");
        require(h.checkBaseNoLeak() && h.checkMarketSolvent(), "ledger broken");
    }

    /// Governance and guard rails: pause is governor/pauseGuardian-gated,
    /// withdrawReserves is governor-only, uncollateralized borrowing reverts.
    function test_governance_and_guards() public {
        address stranger = h.actors(5);
        address governor = h.GOVERNOR();

        _prank(stranger);
        VM.expectRevert(abi.encodeWithSelector(CometMainInterface.Unauthorized.selector));
        comet.pause(true, false, false, false, false);
        _unprank();

        _prank(governor);
        comet.pause(true, false, false, false, false);
        _unprank();
        require(comet.isSupplyPaused(), "supply not paused");

        _prank(governor);
        comet.pause(false, false, false, false, false);
        _unprank();
        require(!comet.isSupplyPaused(), "supply not unpaused");

        _prank(stranger);
        VM.expectRevert(abi.encodeWithSelector(CometMainInterface.Unauthorized.selector));
        comet.withdrawReserves(stranger, 1);
        _unprank();

        // Withdraw base beyond an empty, collateral-less position must revert.
        MockERC20 usdc = h.usdc();
        _prank(stranger);
        VM.expectRevert(abi.encodeWithSelector(CometMainInterface.NotCollateralized.selector));
        comet.withdraw(address(usdc), 100e6);
        _unprank();
    }

    /// A benign supply/withdraw round-trip never shrinks reserves (no free
    /// value extraction through the round trip).
    function test_roundtrip_no_free_value() public {
        address a = h.actors(6);
        int256 before = comet.getReserves();
        _prank(a);
        comet.supply(address(h.usdc()), 500e6);
        comet.withdraw(address(h.usdc()), 500e6);
        _unprank();
        require(comet.getReserves() >= before, "reserves shrank on roundtrip");
        require(h.checkLastResidual() && h.checkBaseNoLeak(), "ledger broken");
    }
}
