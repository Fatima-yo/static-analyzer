// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {CometWithExtendedAssetList} from "../src/core/CometWithExtendedAssetList.sol";
import {CometConfiguration} from "../src/core/CometConfiguration.sol";

import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";
import {MockAssetListFactory} from "../src/mocks/MockAssetListFactory.sol";
import {MockExtensionDelegate} from "../src/mocks/MockExtensionDelegate.sol";

interface Vm {
    function warp(uint256) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert(bytes calldata) external;
    function load(address, bytes32) external view returns (bytes32);
    function log_named_uint(string calldata, uint256) external;
    function log_named_int(string calldata, int256) external;
    function log_named_bool(string calldata, bool) external;
}

/// @notice Invariant harness for compound-v3's Comet (solc 0.8.15, BUSL-1.1).
/// One base asset (USDC, 6dp) and two collateral assets (WETH 18dp, WBTC 8dp)
/// exercise every ledger path: supply/withdraw (base and collateral), transfers,
/// borrow (withdraw beyond balance), repay (supply while borrowed), absorption
/// of underwater accounts under oracle shocks, buyCollateral from absorbed
/// reserves, pause toggling, and interest accrual over time.
///
/// 8 actors are prefunded and route every action as `msg.sender` via prank (all
/// value flows are ERC20 — the balancer-v2 playbook). Every Comet call goes
/// through a low-level call whose revert is swallowed, so handler functions
/// never revert (the rocket-pool lesson: foundry's invariant fuzzer commits
/// state for reverted calls).
///
/// Ledger invariants (all exact):
///  - base principal book: sum(actor positive principal) == totalSupplyBase and
///    sum(actor |negative principal|) == totalBorrowBase (Comet's principal
///    book is stored directly, no share conversion — the sums are exact; only
///    the present-value conversions round, and that rounding lands in reserves).
///  - collateral book: sum(actor collateral) == totalsCollateral per asset
///    (absorb seizes by zeroing the user balance and decrementing totals by the
///    same amount, so the identity survives absorption).
    ///  - reserves no-leak: reserves == balance - presentSupply + presentBorrow
    ///    can only decrease by the debt written off in absorb; accumulated bad
    ///    debt is tracked and offset, so `reserves + absorbedBadDebt >= 0`
    ///    always. Every non-absorb action leaves reserves non-decreasing up to
    ///    one base unit of rounding dust (principalValue/presentValue floors);
    ///    absorb writes off at most the debt the account owed (+DUST). The
    ///    borrow base rate (0.04/yr) makes reserve growth non-negative over the
    ///    whole utilization range (`util*borrowRate >= supplyRate` for all util
    ///    in [0,1]), so interest accrual alone never drains reserves: every
    ///    decline is absorbed bad debt.
    ///  - absorb accounting: reserves delta >= -(debtBefore + DUST) on every
    ///    absorption. (Positive deltas are legal: collateral seized at the
    ///    liquidation factor can over-cover a liquidatable debt and the surplus
    ///    becomes a supply position, growing reserves.)
    ///  - market solvency: balance + totalBorrow + absorbedBadDebt >= totalSupply
    ///    (protocol cash plus borrower claims cover supplier claims).
contract CometHandler {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint256 public constant N_ACTORS = 8;
    uint256 public constant MAX_WARP = 2_592_000; // 30 days
    /// Max 1 base unit (1e-6 USDC) of rounding dust per action: principalValue
    /// (floor) and presentValue (floor) round-trip can move exactly one base
    /// unit out of reserves; a single action can never move more than that, so
    /// any residual below -DUST is a real value leak.
    int256 public constant DUST = 1;
    address public constant GOVERNOR = address(uint160(0x000000000000000000000000000000000000F00D));
    address public constant PAUSE_GUARDIAN = address(uint160(0x00000000000000000000000000000000000000AA));

    uint256 public constant PREFUND_USDC = 1_000_000e6; // 1M USDC
    uint256 public constant PREFUND_WETH = 1000 ether; // 1000 WETH
    uint256 public constant PREFUND_WBTC = 100e8; // 100 WBTC

    int256 public constant PRICE_USDC = 1e8; // $1
    int256 public constant PRICE_WETH = 2000e8; // $2000
    int256 public constant PRICE_WBTC = 30000e8; // $30000

    CometWithExtendedAssetList public comet;
    MockERC20 public usdc;
    MockERC20 public weth;
    MockERC20 public wbtc;
    MockPriceFeed public feedUsdc;
    MockPriceFeed public feedWeth;
    MockPriceFeed public feedWbtc;

    address[8] public actors;

    /// Per-action reserves delta for the last non-absorb routed action. Must be
    /// >= 0: supply/withdraw/borrow/repay/transfer/accrue only grow reserves
    /// (rounding lands in reserves), never shrink them.
    int256 public lastResidual;
    bool public lastResidualValid;

    /// Debt written off by absorb actions (the only legitimate reserve drain),
    /// in present base units. `reserves + absorbedBadDebt` is the protocol's
    /// ledger: never below zero.
    uint256 public absorbedBadDebt;

    /// False once any absorb writes off more debt than the account owed
    /// (reserves delta below -debtBefore). Positive deltas are legitimate:
    /// over-covered collateral creates a supply position and grows reserves.
    bool public absorbAccountingOk = true;

    /// Diagnostics for the last routed action.
    int256 public lastDelta;
    uint256 public lastBound;
    bool public lastIsAbsorb;

    constructor() {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        feedUsdc = new MockPriceFeed(PRICE_USDC);
        feedWeth = new MockPriceFeed(PRICE_WETH);
        feedWbtc = new MockPriceFeed(PRICE_WBTC);

        MockAssetListFactory factory = new MockAssetListFactory();
        MockExtensionDelegate extension = new MockExtensionDelegate(factory);

        CometConfiguration.AssetConfig[] memory colls = new CometConfiguration.AssetConfig[](2);
        colls[0] = CometConfiguration.AssetConfig({
            asset: address(weth),
            priceFeed: address(feedWeth),
            decimals: 18,
            borrowCollateralFactor: 0.8e18,
            liquidateCollateralFactor: 0.9e18,
            liquidationFactor: 0.92e18,
            supplyCap: type(uint128).max
        });
        colls[1] = CometConfiguration.AssetConfig({
            asset: address(wbtc),
            priceFeed: address(feedWbtc),
            decimals: 8,
            borrowCollateralFactor: 0.75e18,
            liquidateCollateralFactor: 0.85e18,
            liquidationFactor: 0.9e18,
            supplyCap: type(uint128).max
        });

        CometConfiguration.Configuration memory config = CometConfiguration.Configuration({
            governor: GOVERNOR,
            pauseGuardian: PAUSE_GUARDIAN,
            baseToken: address(usdc),
            baseTokenPriceFeed: address(feedUsdc),
            extensionDelegate: address(extension),
            supplyKink: 0.8e18,
            supplyPerYearInterestRateSlopeLow: 0.04e18,
            supplyPerYearInterestRateSlopeHigh: 1e18,
            supplyPerYearInterestRateBase: 0,
            borrowKink: 0.8e18,
            borrowPerYearInterestRateSlopeLow: 0.06e18,
            borrowPerYearInterestRateSlopeHigh: 1.2e18,
            borrowPerYearInterestRateBase: 0.04e18,
            storeFrontPriceFactor: 0.5e18,
            trackingIndexScale: 1e15,
            baseTrackingSupplySpeed: 0,
            baseTrackingBorrowSpeed: 0,
            baseMinForRewards: 1,
            baseBorrowMin: 1,
            targetReserves: 0,
            assetConfigs: colls
        });

        comet = new CometWithExtendedAssetList(config);
        comet.initializeStorage();

        for (uint256 i = 0; i < N_ACTORS; ++i) {
            actors[i] = address(uint160(0x1000 + i));
        }

        for (uint256 i = 0; i < N_ACTORS; ++i) {
            usdc.mint(actors[i], PREFUND_USDC);
            weth.mint(actors[i], PREFUND_WETH);
            wbtc.mint(actors[i], PREFUND_WBTC);
            VM.startPrank(actors[i]);
            usdc.approve(address(comet), type(uint256).max);
            weth.approve(address(comet), type(uint256).max);
            wbtc.approve(address(comet), type(uint256).max);
            VM.stopPrank();
        }
    }

    /// Deterministic bounding: preserves in-range values, maps out-of-range
    /// fuzz inputs via modulo.
    function _bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max <= min) return min;
        if (x >= min && x <= max) return x;
        return min + x % (max - min + 1);
    }

    /// Advance time before a routed action so interest has work to accrue.
    function _tick(uint256 amount) internal {
        VM.warp(block.timestamp + amount % MAX_WARP);
    }

    function _token(uint256 c) internal view returns (MockERC20) {
        return c == 0 ? usdc : (c == 1 ? weth : wbtc);
    }

    /// Public-getter helpers (nested-mapping struct getters decode as tuples).
    function _principal(address account) internal view returns (int104) {
        (int104 p, , , , ) = comet.userBasic(account);
        return p;
    }

    function _collateralBal(address account, address token) internal view returns (uint128) {
        (uint128 b, ) = comet.userCollateral(account, token);
        return b;
    }

    function _totalsCollateral(address token) internal view returns (uint128) {
        (uint128 t, ) = comet.totalsCollateral(token);
        return t;
    }

    /// totalSupplyBase / totalBorrowBase are internal in CometStorage; read the
    /// packed second slot directly (slot 0 = the four uint64 indices, slot 1 =
    /// uint104 totalSupplyBase | uint104 totalBorrowBase | uint40 lastAccrualTime
    /// | uint8 pauseFlags). Comet's storage layout is versioned and documented.
    function _totalSupplyBase() internal view returns (uint104) {
        return uint104(uint256(VM.load(address(comet), bytes32(uint256(1)))));
    }

    function _totalBorrowBase() internal view returns (uint104) {
        return uint104(uint256(VM.load(address(comet), bytes32(uint256(1)))) >> 104);
    }

    /// Route a Comet call with `sender` as msg.sender. A reverting protocol
    /// call is swallowed so the handler function itself always succeeds. The
    /// per-action reserves delta is recorded: non-absorb actions must have
    /// delta >= 0 (modulo 1-unit principalValue rounding dust); absorb actions
    /// must not write off more debt than the account owed (delta >= -debtBefore).
    function _call(address sender, bytes memory payload, bool isAbsorb, uint256 absorbDebtBound) internal {
        int256 before = int256(comet.getReserves());
        VM.startPrank(sender);
        (bool success, bytes memory data) = address(comet).call(payload);
        VM.stopPrank();
        int256 afterR = int256(comet.getReserves());
        int256 delta = afterR - before;
        lastDelta = delta;
        lastBound = absorbDebtBound;
        lastIsAbsorb = isAbsorb;
        if (isAbsorb) {
            if (delta < 0 && uint256(-delta) > absorbDebtBound + uint256(DUST)) {
                absorbAccountingOk = false;
            }
            if (delta < 0) absorbedBadDebt += uint256(-delta);
            lastResidualValid = false;
        } else {
            lastResidual = delta;
            lastResidualValid = true;
        }
        success;
        data;
    }

    /* ============================= FUZZ ACTIONS ============================= */

    /// Supply base or collateral to an actor (Comet's single `supply` routes to
    /// the collateral path for non-base assets).
    function supply(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        uint256 c = (idx / N_ACTORS) % 3;
        MockERC20 token = _token(c);
        uint256 bal = token.balanceOf(actors[a]);
        if (bal == 0) return;
        uint256 amt = _bound(amount, 1, bal);
        _call(actors[a], abi.encodeCall(CometWithExtendedAssetList.supply, (address(token), amt)), false, 0);
    }

    /// Withdraw base or collateral; withdrawing base beyond the balance borrows
    /// (Comet's `withdraw` routes to withdrawCollateral for non-base assets).
    function withdraw(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        uint256 c = (idx / N_ACTORS) % 3;
        MockERC20 token = _token(c);
        uint256 bal = c == 0 ? comet.balanceOf(actors[a]) : uint256(_collateralBal(actors[a], address(token)));
        if (bal == 0) return;
        uint256 amt = _bound(amount, 1, bal * 2 + 1);
        _call(actors[a], abi.encodeCall(CometWithExtendedAssetList.withdraw, (address(token), amt)), false, 0);
    }

    /// Transfer base (can push the source into a borrow, which then requires
    /// collateral) or collateral between two actors.
    function transfer(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        uint256 b = (idx / N_ACTORS) % N_ACTORS;
        uint256 c = ((idx / N_ACTORS) / N_ACTORS) % 2; // 0 = base, 1 = collateral
        if (b == a) return;
        if (c == 0) {
            uint256 bal = comet.balanceOf(actors[a]);
            if (bal == 0) return;
            uint256 amt = _bound(amount, 1, bal);
            _call(actors[a], abi.encodeCall(CometWithExtendedAssetList.transfer, (actors[b], amt)), false, 0);
        } else {
            MockERC20 token = ((idx / N_ACTORS) / N_ACTORS / 2) % 2 == 0 ? weth : wbtc;
            uint256 bal = uint256(_collateralBal(actors[a], address(token)));
            if (bal == 0) return;
            uint256 amt = _bound(amount, 1, bal);
            _call(actors[a], abi.encodeCall(CometWithExtendedAssetList.transferAsset, (actors[b], address(token), amt)), false, 0);
        }
    }

    /// Shock a collateral oracle to a random fraction of the honest price
    /// (down to 0.001%), attempt to absorb a random borrower, then restore the
    /// honest price. Absorption writes the debt off the book (the reserves
    /// drain that absorbedBadDebt accounts for). No time is advanced here so
    /// the reserves delta is exactly the written-off debt (interest accrual
    /// happens on the supply/withdraw/transfer ticks between absorbs).
    function absorb(uint256 idx, uint256 shockAmount) external {
        uint256 absorber = idx % N_ACTORS;
        uint256 victim = (idx / N_ACTORS) % N_ACTORS;
        uint256 coll = ((idx / N_ACTORS) / N_ACTORS) % 2;
        int104 vp = _principal(actors[victim]);
        if (vp >= 0) return;
        MockPriceFeed feed = coll == 0 ? feedWeth : feedWbtc;
        int256 base = coll == 0 ? PRICE_WETH : PRICE_WBTC;
        uint256 collBal = uint256(_collateralBal(actors[victim], coll == 0 ? address(weth) : address(wbtc)));
        if (collBal == 0) return;

        int256 shock = int256(1 + shockAmount % 100_000);
        feed.setPrice(base * shock / 100_000);

        uint256 debtBefore = comet.borrowBalanceOf(actors[victim]);
        address[] memory accounts = new address[](1);
        accounts[0] = actors[victim];
        _call(actors[absorber], abi.encodeCall(CometWithExtendedAssetList.absorb, (actors[absorber], accounts)), true, debtBefore);

        feed.setPrice(base);
    }

    /// Buy absorbed collateral from the protocol reserves with base token.
    function buyCollateral(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        MockERC20 token = (idx / N_ACTORS) % 2 == 0 ? weth : wbtc;
        uint256 bal = usdc.balanceOf(actors[a]);
        if (bal == 0) return;
        uint256 amt = _bound(amount, 1, bal);
        _call(actors[a], abi.encodeCall(CometWithExtendedAssetList.buyCollateral, (address(token), 0, amt, actors[a])), false, 0);
    }

    /// Governor toggles pause flags (exercises the Paused() revert paths; the
    /// low-level calls simply fail while paused).
    function pause(uint256 seed) external {
        bool s = seed % 2 == 1;
        bool t = (seed >> 1) % 2 == 1;
        bool w = (seed >> 2) % 2 == 1;
        bool ab = (seed >> 3) % 2 == 1;
        bool buy = (seed >> 4) % 2 == 1;
        _call(GOVERNOR, abi.encodeCall(CometWithExtendedAssetList.pause, (s, t, w, ab, buy)), false, 0);
    }

    function warp(uint256 amount) external {
        VM.warp(block.timestamp + _bound(amount, 0, 365 days));
    }

    /* ============================= INVARIANT CHECKS ============================= */

    /// The base principal book is exact: every positive principal unit lives in
    /// a tracked actor account and equals totalSupplyBase; every borrow unit
    /// equals totalBorrowBase. (Only actors can hold base positions; transfers
    /// are actor-to-actor.)
    function checkBaseBookConserved() external view returns (bool) {
        uint256 posSum;
        uint256 negSum;
        for (uint256 i = 0; i < N_ACTORS; ++i) {
            int104 p = _principal(actors[i]);
            if (p >= 0) posSum += uint104(p);
            else negSum += uint104(-p);
        }
        return posSum == uint256(_totalSupplyBase()) && negSum == uint256(_totalBorrowBase());
    }

    /// The collateral book is exact per asset: every collateral unit lives in a
    /// tracked actor account and equals totalsCollateral.totalSupplyAsset
    /// (absorption seizes both sides by the same amount).
    function checkCollateralBookConserved(uint256 c) external view returns (bool) {
        MockERC20 token = c == 0 ? weth : wbtc;
        uint256 sum;
        for (uint256 i = 0; i < N_ACTORS; ++i) {
            sum += uint256(_collateralBal(actors[i], address(token)));
        }
        return sum == uint256(_totalsCollateral(address(token)));
    }

    /// The protocol ledger never loses value outside of absorbed bad debt:
    /// reserves (= balance - presentSupply + presentBorrow) plus the debt
    /// absorbed so far is always >= 0.
    function checkBaseNoLeak() external view returns (bool) {
        return int256(comet.getReserves()) + int256(absorbedBadDebt) >= 0;
    }

    /// Every non-absorb action leaves reserves non-decreasing up to rounding
    /// dust: principalValue (floor) paired with presentValue (floor) can move
    /// exactly one base unit out of reserves on any supply/withdraw/borrow/
    /// repay/transfer, so delta >= -DUST. Anything below -DUST is a real leak.
    function checkLastResidual() external view returns (bool) {
        return !lastResidualValid || lastResidual >= -DUST;
    }

    /// Absorb never writes off more debt than the account owed (up to DUST of
    /// index/PV rounding: the write-off can exceed the measured borrowBalanceOf
    /// by exactly one base unit). (The upper bound is intentionally not
    /// enforced: when seized collateral at the liquidation factor over-covers
    /// the debt - a liquidatable band exists between liquidateCollateralFactor
    /// and liquidationFactor - the surplus becomes a supply position and
    /// reserves legitimately grow, up to the debt.)
    function checkAbsorbAccounting() external view returns (bool) {
        return absorbAccountingOk;
    }

    /// Decimal string for a uint256 (diagnostics in invariant failure messages).
    function uint2str(uint256 v) external pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory buf = new bytes(78);        uint256 i = 78;
        while (v > 0) {
            i -= 1;
            buf[i] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        bytes memory out = new bytes(78 - i);
        for (uint256 j = 0; j < out.length; ++j) out[j] = buf[i + j];
        return string(out);
    }

    /// Market solvency: the protocol can cover every supplier claim from its
    /// base cash plus what borrowers owe, even crediting back the bad debt it
    /// already wrote off. `reserves = balance - presentSupply + presentBorrow`
    /// gives `balance + presentBorrow + absorbedBadDebt >= presentSupply`
    /// directly. (Comet's raw `totalSupply >= totalBorrow` is NOT a solvency
    /// statement - the borrow index grows faster than the supply index, so
    /// presentBorrow exceeds presentSupply in the profitable case.)
    function checkMarketSolvent() external view returns (bool) {
        return
            int256(usdc.balanceOf(address(comet))) +
            int256(comet.totalBorrow()) +
            int256(absorbedBadDebt) >=
            int256(comet.totalSupply());
    }

    /// Debug helper: full ledger breakdown for a failing invariant.
    function ledgerBreakdown()
        external
        view
        returns (
            uint256 cometUsdc,
            uint256 cometWeth,
            uint256 cometWbtc,
            int256 reserves,
            uint256 absorbed,
            uint256 trackedPos,
            uint256 trackedNeg,
            uint256 bookPos,
            uint256 bookNeg,
            uint256 collWeth,
            uint256 collWbtc,
            uint256 bookCollWeth,
            uint256 bookCollWbtc,
            uint256 totalSupply,
            uint256 totalBorrow
        )
    {
        uint256 posSum;
        uint256 negSum;
        for (uint256 i = 0; i < N_ACTORS; ++i) {
            int104 p = _principal(actors[i]);
            if (p >= 0) posSum += uint104(p);
            else negSum += uint104(-p);
        }
        uint256 cw;
        for (uint256 i = 0; i < N_ACTORS; ++i) cw += uint256(_collateralBal(actors[i], address(weth)));
        uint256 cb;
        for (uint256 i = 0; i < N_ACTORS; ++i) cb += uint256(_collateralBal(actors[i], address(wbtc)));
        return (
            usdc.balanceOf(address(comet)),
            weth.balanceOf(address(comet)),
            wbtc.balanceOf(address(comet)),
            int256(comet.getReserves()),
            absorbedBadDebt,
            posSum,
            negSum,
            uint256(_totalSupplyBase()),
            uint256(_totalBorrowBase()),
            cw,
            cb,
            uint256(_totalsCollateral(address(weth))),
            uint256(_totalsCollateral(address(wbtc))),
            comet.totalSupply(),
            comet.totalBorrow()
        );
    }
}
