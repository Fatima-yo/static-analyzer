// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {Morpho} from "../src/core/Morpho.sol";
import {Id, MarketParams} from "../src/core/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../src/core/libraries/MarketParamsLib.sol";

import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {MockIrm} from "../src/mocks/MockIrm.sol";

interface Vm {
    function warp(uint256) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert(bytes calldata) external;
}

/// @notice Read-surface ABI mirror (matches IMorphoStaticTyping at the ABI
/// level: struct returns decode as tuples).
interface IMorphoRead {
    function position(Id id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
    function market(Id id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );
    function owner() external view returns (address);
    function feeRecipient() external view returns (address);
}

/// @notice Action-surface ABI mirror used to build calldata for the real
/// Morpho contract (selectors are identical).
interface IMorphoActions {
    function supply(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256);
    function withdraw(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256);
    function borrow(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256);
    function repay(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256);
    function supplyCollateral(
        MarketParams calldata marketParams,
        uint256 assets,
        address onBehalf,
        bytes calldata data
    ) external;
    function withdrawCollateral(
        MarketParams calldata marketParams,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external;
    function liquidate(
        MarketParams calldata marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256, uint256);
    function accrueInterest(MarketParams calldata marketParams) external;
    function setFee(MarketParams calldata marketParams, uint256 newFee) external;
    function setFeeRecipient(address newFeeRecipient) external;
    function setOwner(address newOwner) external;
}

/// @notice Invariant harness for morpho-blue's Morpho (solc 0.8.19, BUSL-1.1).
/// Two cross-token markets exercise every ledger path:
///   market A: loan USDC(6dp), collateral WETH(18dp), oracle 2000 USDC/WETH,
///             lltv 86%, fee 10%
///   market B: loan WETH(18dp), collateral USDC(6dp), oracle 1/2000 WETH/USDC,
///             lltv 80%, fee 0%
/// 8 actors hold pre-funded USDC+WETH and route every action as `msg.sender`
/// via prank (no ETH is ever moved — all value flows are ERC20, so prank-based
/// sender redirection is safe; this is the balancer-v2 playbook). Every Morpho
/// call goes through a low-level call whose revert is swallowed, so handler
/// functions never revert (the rocket-pool lesson: foundry's invariant fuzzer
/// commits state for reverted calls, foundry_invariant.rs:547).
contract MorphoHandler {
    using MarketParamsLib for MarketParams;

    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint256 public constant N_ACTORS = 8;
    uint256 public constant ORACLE_A_BASE = 2e27; // 2000e6 USDC per WETH, scaled 1e36
    uint256 public constant ORACLE_B_BASE = 5e44; // 0.0005e18 WETH per USDC, scaled 1e36
    uint256 public constant BORROW_RATE = uint256(0.05e18) / 365 days; // 5% APR, per-second WAD
    uint256 public constant PREFUND_USDC = 1_000_000e6; // 1M USDC
    uint256 public constant PREFUND_WETH = 1000 ether;
    uint256 public constant MAX_WARP = 2_592_000; // 30 days
    address public constant OWNER = address(uint160(0x000000000000000000000000000000000000F00D));
    address public constant FEE_RECIPIENT = address(uint160(0x000000000000000000000000000000000000bEEF));

    Morpho public morpho;
    MockERC20 public usdc;
    MockERC20 public weth;
    MockOracle public oracleA;
    MockOracle public oracleB;
    MockIrm public irm;

    /// Per-action ledger residual: (morpho physical token delta) minus (book
    /// idle delta) for the last routed action. Morpho's virtual-share rounding
    /// lets one action push this to exactly +1 (repaying the last borrow share
    /// overpays 1 wei into the pool); anything else is value leakage.
    int256 public lastUsdcResidual;
    int256 public lastWethResidual;

    MarketParams[2] public mps;
    Id[2] public ids;
    address[8] public actors;

    /// Struct-typed getter (the auto-generated `mps(uint256)` returns a tuple,
    /// which cannot be passed to functions taking `MarketParams memory`).
    function mp(uint256 m) external view returns (MarketParams memory) {
        return mps[m];
    }

    constructor() {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        irm = new MockIrm(BORROW_RATE);
        oracleA = new MockOracle(ORACLE_A_BASE);
        oracleB = new MockOracle(ORACLE_B_BASE);
        morpho = new Morpho(OWNER);

        for (uint256 i = 0; i < N_ACTORS; ++i) {
            actors[i] = address(uint160(0x1000 + i));
        }

        VM.startPrank(OWNER);
        morpho.enableIrm(address(irm));
        morpho.enableLltv(0.86e18);
        morpho.enableLltv(0.8e18);
        morpho.setFeeRecipient(FEE_RECIPIENT);
        VM.stopPrank();

        mps[0] = MarketParams(address(usdc), address(weth), address(oracleA), address(irm), 0.86e18);
        mps[1] = MarketParams(address(weth), address(usdc), address(oracleB), address(irm), 0.8e18);
        ids[0] = mps[0].id();
        ids[1] = mps[1].id();

        morpho.createMarket(mps[0]);
        morpho.createMarket(mps[1]);

        VM.startPrank(OWNER);
        morpho.setFee(mps[0], 0.1e18);
        VM.stopPrank();

        for (uint256 i = 0; i < N_ACTORS; ++i) {
            usdc.mint(actors[i], PREFUND_USDC);
            weth.mint(actors[i], PREFUND_WETH);
            VM.startPrank(actors[i]);
            usdc.approve(address(morpho), type(uint256).max);
            weth.approve(address(morpho), type(uint256).max);
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

    /// Advance time before a routed action so `_accrueInterest` has work to do.
    function _tick(uint256 amount) internal {
        VM.warp(block.timestamp + amount % MAX_WARP);
    }

    function _loan(uint256 m) internal view returns (MockERC20) {
        return m == 0 ? usdc : weth;
    }

    function _coll(uint256 m) internal view returns (MockERC20) {
        return m == 0 ? weth : usdc;
    }

    function _pos(uint256 m, address user) internal view returns (uint256, uint128, uint128) {
        return IMorphoRead(address(morpho)).position(ids[m], user);
    }

    function _market(uint256 m)
        internal
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        )
    {
        return IMorphoRead(address(morpho)).market(ids[m]);
    }

    /// Route a Morpho call with `sender` as msg.sender. A reverting protocol
    /// call is swallowed so the handler function itself always succeeds. The
    /// per-action ledger residual for both tokens is recorded: the physical
    /// balance move must equal the book-idle move (or exceed it by the
    /// protocol's 1-wei repay rounding).
    function _call(address sender, bytes memory payload) internal {
        uint256 uBefore = usdc.balanceOf(address(morpho));
        uint256 wBefore = weth.balanceOf(address(morpho));
        (int256 iuBefore, int256 iwBefore) = _idle();
        VM.startPrank(sender);
        (bool success, bytes memory data) = address(morpho).call(payload);
        VM.stopPrank();
        uint256 uAfter = usdc.balanceOf(address(morpho));
        uint256 wAfter = weth.balanceOf(address(morpho));
        (int256 iuAfter, int256 iwAfter) = _idle();
        lastUsdcResidual = int256(uAfter) - int256(uBefore) - (iuAfter - iuBefore);
        lastWethResidual = int256(wAfter) - int256(wBefore) - (iwAfter - iwBefore);
        success;
        data;
    }

    /// Book-idle value per token, signed to avoid underflow: USDC = m0 supply -
    /// m0 borrow + m1 collateral; WETH = m1 supply - m1 borrow + m0 collateral.
    function _idle() internal view returns (int256 usdcIdle, int256 wethIdle) {
        (uint128 saA, , uint128 baA, , , ) = _market(0);
        (uint128 saB, , uint128 baB, , , ) = _market(1);
        usdcIdle = int256(uint256(saA)) - int256(uint256(baA)) + int256(_sumCollateral(1));
        wethIdle = int256(uint256(saB)) - int256(uint256(baB)) + int256(_sumCollateral(0));
    }

    /* ============================= FUZZ ACTIONS ============================= */

    function supply(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        uint256 m = (idx / N_ACTORS) % 2;
        uint256 bal = _loan(m).balanceOf(actors[a]);
        if (bal == 0) return;
        if ((amount >> 8) % 2 == 0) {
            uint256 amt = _bound(amount, 1, bal);
            _call(actors[a], abi.encodeCall(IMorphoActions.supply, (mps[m], amt, 0, actors[a], "")));
        } else {
            if (bal < 1e6) return;
            uint256 shares = _bound(amount, 1, bal / 1e6);
            _call(actors[a], abi.encodeCall(IMorphoActions.supply, (mps[m], 0, shares, actors[a], "")));
        }
    }

    function supplyCollateral(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        uint256 m = (idx / N_ACTORS) % 2;
        uint256 bal = _coll(m).balanceOf(actors[a]);
        if (bal == 0) return;
        uint256 amt = _bound(amount, 1, bal);
        _call(actors[a], abi.encodeCall(IMorphoActions.supplyCollateral, (mps[m], amt, actors[a], "")));
    }

    function borrow(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        uint256 m = (idx / N_ACTORS) % 2;
        (, , uint128 coll) = _pos(m, actors[a]);
        if (coll == 0) return;
        uint256 price = m == 0 ? oracleA.price_() : oracleB.price_();
        uint256 lltv = m == 0 ? 0.86e18 : 0.8e18;
        uint256 maxBorrow = uint256(coll) * price / 1e36 * lltv / 1e18;
        if (maxBorrow < 2) return;
        uint256 amt = _bound(amount, 1, maxBorrow / 2);
        _call(actors[a], abi.encodeCall(IMorphoActions.borrow, (mps[m], amt, 0, actors[a], actors[a])));
    }

    function withdraw(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        uint256 m = (idx / N_ACTORS) % 2;
        (uint256 sShares, , ) = _pos(m, actors[a]);
        if (sShares == 0) return;
        uint256 shares = _bound(amount, 1, sShares);
        _call(actors[a], abi.encodeCall(IMorphoActions.withdraw, (mps[m], 0, shares, actors[a], actors[a])));
    }

    function withdrawCollateral(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        uint256 m = (idx / N_ACTORS) % 2;
        (, , uint128 coll) = _pos(m, actors[a]);
        if (coll == 0) return;
        uint256 amt = _bound(amount, 1, coll);
        _call(actors[a], abi.encodeCall(IMorphoActions.withdrawCollateral, (mps[m], amt, actors[a], actors[a])));
    }

    function repay(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        uint256 m = (idx / N_ACTORS) % 2;
        (, uint128 bShares, ) = _pos(m, actors[a]);
        if (bShares == 0) return;
        uint256 shares = _bound(amount, 1, bShares);
        _call(actors[a], abi.encodeCall(IMorphoActions.repay, (mps[m], 0, shares, actors[a], "")));
    }

    /// Shock the oracle of market `m` to a random fraction of the base price
    /// (down to 0.001%), attempt a liquidation on a random borrower, then
    /// restore the honest price. Every ledger invariant is price-independent,
    /// so the invariants can be evaluated at the base price.
    function liquidate(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        uint256 m = (idx / N_ACTORS) % 2;
        address borrower = actors[a];
        (, uint128 bShares, uint128 coll) = _pos(m, borrower);
        if (bShares == 0 && coll == 0) return;

        MockOracle oracle = m == 0 ? oracleA : oracleB;
        uint256 base = m == 0 ? ORACLE_A_BASE : ORACLE_B_BASE;
        uint256 shock = 1 + amount % 100_000;
        oracle.setPrice(base * shock / 100_000);

        uint256 seized;
        uint256 repaid;
        if (bShares == 0) {
            seized = _bound(amount, 1, coll);
        } else if (coll == 0) {
            repaid = _bound(amount, 1, bShares);
        } else if ((amount >> 8) % 2 == 0) {
            seized = _bound(amount, 1, coll);
        } else {
            repaid = _bound(amount, 1, bShares);
        }

        _call(borrower, abi.encodeCall(IMorphoActions.liquidate, (mps[m], borrower, seized, repaid, "")));

        oracle.setPrice(base);
    }

    function accrue(uint256 idx) external {
        uint256 m = idx % 2;
        VM.warp(block.timestamp + 1);
        _call(actors[0], abi.encodeCall(IMorphoActions.accrueInterest, (mps[m])));
    }

    function warp(uint256 amount) external {
        VM.warp(block.timestamp + _bound(amount, 0, 365 days));
    }

    function setFee(uint256 idx, uint256 amount) external {
        if (IMorphoRead(address(morpho)).owner() != OWNER) return;
        uint256 m = idx % 2;
        uint256 fee;
        uint256 sel = amount % 4;
        if (sel == 0) fee = 0;
        else if (sel == 1) fee = 0.05e18;
        else if (sel == 2) fee = 0.1e18;
        else fee = 0.25e18;
        (uint128 tsa, uint128 tss, uint128 tba, uint128 tbs, uint128 lu, uint128 curFee) = _market(m);
        tsa; tss; tba; tbs; lu;
        if (fee == curFee) return;
        _call(OWNER, abi.encodeCall(IMorphoActions.setFee, (mps[m], fee)));
    }

    function setFeeRecipient(uint256 idx, uint256 amount) external {
        if (IMorphoRead(address(morpho)).owner() != OWNER) return;
        address candidate = (amount % (N_ACTORS + 1)) == N_ACTORS ? address(0) : actors[amount % N_ACTORS];
        if (candidate == IMorphoRead(address(morpho)).feeRecipient()) return;
        _call(OWNER, abi.encodeCall(IMorphoActions.setFeeRecipient, (candidate)));
    }

    function setOwner(uint256 idx, uint256 amount) external {
        if (IMorphoRead(address(morpho)).owner() != OWNER) return;
        address candidate = (amount % (N_ACTORS + 1)) == N_ACTORS ? address(0) : actors[amount % N_ACTORS];
        if (candidate == IMorphoRead(address(morpho)).owner()) return;
        _call(OWNER, abi.encodeCall(IMorphoActions.setOwner, (candidate)));
    }

    /* ============================= INVARIANT CHECKS ============================= */

    /// The supply-share ledger is exact: every share on the books lives in a
    /// tracked position (8 actors + feeRecipient + address(0), which covers any
    /// feeRecipient morpho-blue's owner can set).
    function checkSupplySharesConserved(uint256 m) external view returns (bool) {
        uint256 sum;
        for (uint256 i = 0; i < N_ACTORS; ++i) {
            (uint256 sShares, , ) = _pos(m, actors[i]);
            sum += sShares;
        }
        (uint256 fShares, , ) = _pos(m, FEE_RECIPIENT);
        sum += fShares;
        (uint256 zShares, , ) = _pos(m, address(0));
        sum += zShares;
        (uint128 tsa, uint128 tss, uint128 tba, uint128 tbs, uint128 lu, uint128 fee) = _market(m);
        tsa; tba; tbs; lu; fee;
        return sum == uint256(tss);
    }

    /// The borrow-share ledger is exact (only actors can hold borrow shares).
    function checkBorrowSharesConserved(uint256 m) external view returns (bool) {
        uint256 sum;
        for (uint256 i = 0; i < N_ACTORS; ++i) {
            (, uint128 bShares, ) = _pos(m, actors[i]);
            sum += bShares;
        }
        (uint128 tsa, uint128 tss, uint128 tba, uint128 tbs, uint128 lu, uint128 fee) = _market(m);
        tsa; tss; tba; lu; fee;
        return sum == uint256(tbs);
    }

    /// A market's supply book can never be under water relative to its borrow
    /// book (bad-debt write-offs keep it >= 0).
    function checkMarketSolvent(uint256 m) external view returns (bool) {
        (uint128 tsa, , uint128 tba, , , ) = _market(m);
        return uint256(tsa) >= uint256(tba);
    }

    /// Cross-token balance-sheet identity, no-value-creation lower bound:
    /// morpho's physical token balance must never fall below the idle pool of
    /// the market that lends it plus the collateral the market that accepts it
    /// holds on behalf of users. USDC: idle_A + coll_B; WETH: idle_B + coll_A.
    /// The physical balance may exceed the book by Morpho's cumulative 1-wei
    /// repay rounding (see `lastUsdcResidual`/`lastWethResidual` for the exact
    /// per-action bound).
    function checkTokenBalance(uint256 t) external view returns (bool) {
        (uint128 saA, , uint128 baA, , , ) = _market(0);
        (uint128 saB, , uint128 baB, , , ) = _market(1);
        if (uint256(saA) < uint256(baA) || uint256(saB) < uint256(baB)) return false;
        uint256 collB = _sumCollateral(1);
        uint256 collA = _sumCollateral(0);
        if (t == 0) {
            uint256 rhs = uint256(saA) - uint256(baA) + collB;
            return usdc.balanceOf(address(morpho)) >= rhs;
        }
        uint256 rhsB = uint256(saB) - uint256(baB) + collA;
        return weth.balanceOf(address(morpho)) >= rhsB;
    }

    /// Every token-moving action must leave the USDC ledger residual in {0, 1}
    /// (0 for exact book moves, +1 for the protocol's repay rounding).
    function checkUsdcResidual() external view returns (bool) {
        return lastUsdcResidual >= 0 && lastUsdcResidual <= 1;
    }

    /// Every token-moving action must leave the WETH ledger residual in {0, 1}.
    function checkWethResidual() external view returns (bool) {
        return lastWethResidual >= 0 && lastWethResidual <= 1;
    }

    function _sumCollateral(uint256 m) internal view returns (uint256) {
        uint256 sum;
        for (uint256 i = 0; i < N_ACTORS; ++i) {
            (, , uint128 coll) = _pos(m, actors[i]);
            sum += coll;
        }
        return sum;
    }

    /// Debug helper: full ledger breakdown for a failing invariant.
    function conservationBreakdown()
        external
        view
        returns (
            uint256 morphoUsdc,
            uint256 morphoWeth,
            uint256 saA,
            uint256 baA,
            uint256 saB,
            uint256 baB,
            uint256 collA,
            uint256 collB,
            uint256 totalSupplySharesA,
            uint256 totalBorrowSharesA,
            uint256 totalSupplySharesB,
            uint256 totalBorrowSharesB,
            uint256 trackedSupplySharesA,
            uint256 trackedBorrowSharesA,
            uint256 trackedSupplySharesB,
            uint256 trackedBorrowSharesB
        )
    {
        (uint128 saA_, , uint128 baA_, , , ) = _market(0);
        (uint128 saB_, , uint128 baB_, , , ) = _market(1);
        (uint128 tsa0, uint128 tss0, , uint128 tbs0, , ) = _market(0);
        (uint128 tsa1, uint128 tss1, , uint128 tbs1, , ) = _market(1);
        tsa0; tsa1;
        return (
            usdc.balanceOf(address(morpho)),
            weth.balanceOf(address(morpho)),
            uint256(saA_),
            uint256(baA_),
            uint256(saB_),
            uint256(baB_),
            _sumCollateral(0),
            _sumCollateral(1),
            uint256(tss0),
            uint256(tbs0),
            uint256(tss1),
            uint256(tbs1),
            _trackedSupply(0),
            _trackedBorrow(0),
            _trackedSupply(1),
            _trackedBorrow(1)
        );
    }

    function _trackedSupply(uint256 m) internal view returns (uint256) {
        uint256 sum;
        for (uint256 i = 0; i < N_ACTORS; ++i) {
            (uint256 sShares, , ) = _pos(m, actors[i]);
            sum += sShares;
        }
        (uint256 fShares, , ) = _pos(m, FEE_RECIPIENT);
        (uint256 zShares, , ) = _pos(m, address(0));
        return sum + fShares + zShares;
    }

    function _trackedBorrow(uint256 m) internal view returns (uint256) {
        uint256 sum;
        for (uint256 i = 0; i < N_ACTORS; ++i) {
            (, uint128 bShares, ) = _pos(m, actors[i]);
            sum += bShares;
        }
        return sum;
    }
}
