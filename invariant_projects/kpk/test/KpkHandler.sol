// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {KpkShares} from "../src/kpkShares.sol";
import {IkpkShares} from "../src/IkpkShares.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockPerfFeeModule} from "../src/mocks/MockPerfFeeModule.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface Vm {
    function warp(uint256) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert(bytes calldata) external;
}

/// @notice Invariant harness for kpk's KpkShares fund vault (solc 0.8.24,
/// OZ v5.0 vendored). A UUPS proxy deployed like the factory's shares proxy
/// is initialized with a USDC base asset, an operator, a portfolio Safe that
/// holds the fund's assets (the real deployment is a Gnosis Safe wired by
/// KpkOivFactory), two extra deposit/redeem assets, management/redemption/
/// performance fees and a deterministic perf-fee module. 6 actors prefunded
/// with every asset route all actions via prank (all value flows are ERC20 —
/// the balancer-v2 playbook).
///
/// Every protocol call goes through a low-level call whose revert is
/// swallowed, so handler functions never revert (the rocket-pool lesson:
/// foundry's invariant fuzzer commits state for reverted calls). Handler-side
/// accumulators (the request shadow book) are only updated when the routed
/// call succeeds.
///
/// Ledger invariants (both exact):
///  - share book: totalSupply == vault share balance (redemption escrow)
///    + fee-receiver A + fee-receiver B + sum(actor balances). Every mint
///    (subscription approval to a receiver, management/performance fee to the
///    fee receiver) and every burn (redemption approval burns net shares from
///    the escrow) and every transfer (subscription/redemption escrow,
///    reject/cancel returns, redemption fee) is reflected in exactly one of
///    those buckets, so a double mint, a skipped burn or a mistargeted
///    transfer breaks it exactly.
///  - asset escrow: for every approved asset, asset.balanceOf(vault) ==
///    subscriptionAssets[asset]. Subscriptions pull assets in and every exit
///    path (approve -> portfolioSafe, reject/cancel -> investor) debits the
///    escrow book by the same amount it debits the balance; recoverAssets only
///    sweeps when the escrow book is empty, so the identity is exact.
///
/// Time is advanced on most actions (0..7 days) so management/performance
/// fees (charged only after MIN_TIME_ELAPSED = 6h) accrue and requests hit
/// both the TTL (cancellation) and MAX_TTL (7-day expiry auto-reject) paths.
contract KpkHandler {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint256 public constant N_ACTORS = 6;
    uint256 public constant MAX_WARP = 7 days;

    address public constant ADMIN = address(uint160(0x2000));
    address public constant OPERATOR = address(uint160(0x3000));
    address public constant FEE_RECEIVER_A = address(uint160(0x4000));
    address public constant FEE_RECEIVER_B = address(uint160(0x4001));
    address public constant SAFE = address(uint160(0x5000));

    uint256 public constant BASE_PRICE = 1e8; // $1 per share, 8dp USD
    uint256 public constant ALT_PRICE = 3000e8; // $3000 per share
    uint256 public constant SPARE_PRICE = 100e8; // $100 per share

    uint256 public constant PREFUND_6 = 1_000_000e6; // 1M USDC per actor
    uint256 public constant PREFUND_18 = 1_000_000e18; // 1M wei-based per actor
    uint256 public constant SAFE_PREFUND_6 = 1e18; // 1e12 USDC units at the Safe
    uint256 public constant SAFE_PREFUND_18 = 1e30; // 1e12 WETH wei at the Safe

    /// RecoverFunds.recoverAssets is not visible for abi.encodeCall through the
    /// KpkShares type (inherited, not redeclared), so route it by selector.
    bytes4 internal constant RECOVER = bytes4(keccak256("recoverAssets(address[])"));

    KpkShares public vault;
    KpkShares public impl;
    MockPerfFeeModule public perfModule;

    MockERC20[3] public assets;
    uint256[3] public initialPrices;

    address[N_ACTORS] public actors;

    /// Shadow book of created requests (bias fuzz selection toward requests
    /// that are still actionable; stale entries just revert when routed).
    struct ShadowReq {
        uint256 id;
        address investor;
        bool isSub;
        address asset;
    }
    ShadowReq[] public shadow;

    /// Diagnostics for the last routed action.
    bool public lastSuccess;
    bytes public lastReturnData;

    constructor() {
        assets[0] = new MockERC20("USD Coin", "USDC", 6);
        assets[1] = new MockERC20("Wrapped Ether", "WETH", 18);
        assets[2] = new MockERC20("Spare Token", "SPARE", 18);
        initialPrices[0] = BASE_PRICE;
        initialPrices[1] = ALT_PRICE;
        initialPrices[2] = SPARE_PRICE;
        perfModule = new MockPerfFeeModule();
        impl = new KpkShares();
        vault = KpkShares(address(new ERC1967Proxy(address(impl), "")));

        for (uint256 i = 0; i < N_ACTORS; ++i) {
            actors[i] = address(uint160(0x1000 + i));
        }

        KpkShares.ConstructorParams memory params = KpkShares.ConstructorParams({
            asset: address(assets[0]),
            admin: ADMIN,
            name: "KPK Shares",
            symbol: "KPK",
            safe: SAFE,
            subscriptionRequestTtl: uint64(1 days),
            redemptionRequestTtl: uint64(1 days),
            feeReceiver: FEE_RECEIVER_A,
            managementFeeRate: 500, // 5%
            redemptionFeeRate: 100, // 1%
            performanceFeeModule: address(perfModule),
            performanceFeeRate: 200 // 2%
        });
        VM.startPrank(ADMIN);
        vault.initialize(params);
        vault.grantRole(vault.OPERATOR(), OPERATOR);
        VM.stopPrank();
        VM.startPrank(OPERATOR);
        vault.updateAsset(address(assets[1]), false, true, true);
        vault.updateAsset(address(assets[2]), false, true, true);
        VM.stopPrank();

        for (uint256 i = 0; i < N_ACTORS; ++i) {
            assets[0].mint(actors[i], PREFUND_6);
            assets[1].mint(actors[i], PREFUND_18);
            assets[2].mint(actors[i], PREFUND_18);
        }
        for (uint256 i = 0; i < N_ACTORS; ++i) {
            VM.startPrank(actors[i]);
            assets[0].approve(address(vault), type(uint256).max);
            assets[1].approve(address(vault), type(uint256).max);
            assets[2].approve(address(vault), type(uint256).max);
            VM.stopPrank();
        }

        // The portfolio Safe holds the fund's assets and grants the vault a
        // standing allowance so redemption approvals can safeTransferFrom it
        // (the real Safe's exec-approve is wired by the factory).
        assets[0].mint(SAFE, SAFE_PREFUND_6);
        assets[1].mint(SAFE, SAFE_PREFUND_18);
        assets[2].mint(SAFE, SAFE_PREFUND_18);
        VM.startPrank(SAFE);
        assets[0].approve(address(vault), type(uint256).max);
        assets[1].approve(address(vault), type(uint256).max);
        assets[2].approve(address(vault), type(uint256).max);
        VM.stopPrank();
    }

    function _bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max <= min) return min;
        if (x >= min && x <= max) return x;
        return min + x % (max - min + 1);
    }

    /// Advance time before a routed action (0..7 days) so fees accrue and
    /// requests age through TTL/expiry windows.
    function _tick(uint256 amount) internal {
        VM.warp(block.timestamp + amount % MAX_WARP);
    }

    /// Route a vault call with `sender` as msg.sender. A reverting protocol
    /// call is swallowed so the handler function itself always succeeds.
    function _call(address target, address sender, bytes memory payload) internal returns (bool) {
        VM.startPrank(sender);
        (bool success, bytes memory data) = target.call(payload);
        VM.stopPrank();
        lastSuccess = success;
        lastReturnData = data;
        return success;
    }

    function _assetOf(uint256 seed) internal view returns (MockERC20) {
        return assets[seed % 3];
    }

    /// Price the operator is allowed to pass: within 10% of the last settled
    /// price (the protocol enforces a 30% deviation band), or the initial
    /// price when nothing has been settled yet.
    function _priceOf(MockERC20 tok) internal view returns (uint256) {
        uint256 settled = vault.getLastSettledPrice(address(tok));
        if (settled == 0) {
            return initialPrices[_indexOf(address(tok))];
        }
        return settled;
    }

    function _indexOf(address tok) internal view returns (uint256) {
        for (uint256 i = 0; i < 3; ++i) {
            if (address(assets[i]) == tok) return i;
        }
        return 0;
    }

    /* ============================= FUZZ ACTIONS ============================= */

    /// Subscribe: pull assets into the vault's escrow and create a PENDING
    /// subscription request with a mostly-achievable min-shares bound.
    function requestSubscriptionAction(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        MockERC20 tok = _assetOf(idx / N_ACTORS);
        uint256 bal = tok.balanceOf(actors[a]);
        if (bal == 0) return;
        uint256 amt = _bound(amount, 1, bal);
        uint256 est = vault.assetsToShares(amt, _priceOf(tok), address(tok));
        uint256 factor = _bound(amount >> 1, 200, 1500); // 20%..150% of est
        uint256 minShares = (est * factor) / 1000;
        if (minShares == 0) minShares = 1;
        address receiver = actors[(idx / N_ACTORS / 3 + a) % N_ACTORS];
        if (_call(address(vault), actors[a], abi.encodeCall(KpkShares.requestSubscription, (amt, minShares, address(tok), receiver)))) {
            shadow.push(ShadowReq(abi.decode(lastReturnData, (uint256)), actors[a], true, address(tok)));
        }
    }

    /// Cancel a subscription request after its TTL (bias to a real, valid one).
    function cancelSubscriptionAction(uint256 idx, uint256 seed) external {
        if (shadow.length == 0) return;
        ShadowReq memory s = shadow[(idx * 7 + seed) % shadow.length];
        if (!s.isSub) return;
        VM.warp(block.timestamp + 1 days + (seed >> 2) % 6 days);
        _call(address(vault), s.investor, abi.encodeCall(KpkShares.cancelSubscription, (s.id)));
    }

    /// Request a redemption: escrow shares and create a PENDING redemption
    /// request with a mostly-achievable min-assets bound.
    function requestRedemptionAction(uint256 idx, uint256 amount) external {
        _tick(amount);
        uint256 a = idx % N_ACTORS;
        MockERC20 tok = _assetOf(idx / N_ACTORS);
        uint256 shares = vault.balanceOf(actors[a]);
        if (shares == 0) return;
        uint256 amt = _bound(amount, 1, shares);
        uint256 est = vault.sharesToAssets(amt, _priceOf(tok), address(tok));
        uint256 factor = _bound(amount >> 1, 200, 1500);
        uint256 minAssets = (est * factor) / 1000;
        if (minAssets == 0) minAssets = 1;
        address receiver = actors[(idx / N_ACTORS / 3 + a) % N_ACTORS];
        if (_call(address(vault), actors[a], abi.encodeCall(KpkShares.requestRedemption, (amt, minAssets, address(tok), receiver)))) {
            shadow.push(ShadowReq(abi.decode(lastReturnData, (uint256)), actors[a], false, address(tok)));
        }
    }

    /// Cancel a redemption request after its TTL (returns escrowed shares).
    function cancelRedemptionAction(uint256 idx, uint256 seed) external {
        if (shadow.length == 0) return;
        ShadowReq memory s = shadow[(idx * 7 + seed) % shadow.length];
        if (s.isSub) return;
        VM.warp(block.timestamp + 1 days + (seed >> 2) % 6 days);
        _call(address(vault), s.investor, abi.encodeCall(KpkShares.cancelRedemption, (s.id)));
    }

    /// Operator approves/rejects pending requests for a random asset at a
    /// price within the deviation band (rarely a wild price that the band
    /// rejects, exercising the swallowed revert path).
    function processAction(uint256 idx, uint256 seed) external {
        _tick(seed);
        MockERC20 tok = _assetOf(idx);
        uint256 settled = vault.getLastSettledPrice(address(tok));
        uint256 price;
        if (seed % 8 == 0) {
            price = settled == 0 ? 1e30 : (settled * 1500) / 1000;
        } else {
            uint256 delta = 100 - (seed >> 3) % 200; // -10%..+10%
            price = settled == 0 ? _priceOf(tok) : (settled * (1000 + delta)) / 1000;
        }

        uint256[] memory app = new uint256[](3);
        uint256[] memory rej = new uint256[](2);
        uint256 na = 0;
        uint256 nr = 0;
        if (shadow.length > 0) {
            for (uint256 k = 0; k < 4 && na < 3; ++k) {
                ShadowReq memory s = shadow[(seed >> (2 + k)) % shadow.length];
                if (s.asset != address(tok)) continue;
                (bool ok, bytes memory dd) =
                    address(vault).staticcall(abi.encodeCall(KpkShares.getRequest, (s.id)));
                if (!ok) continue;
                IkpkShares.UserRequest memory r = abi.decode(dd, (IkpkShares.UserRequest));
                if (r.requestStatus == IkpkShares.RequestStatus.PENDING) {
                    app[na++] = s.id;
                }
            }
            for (uint256 k = 0; k < 2 && nr < 2; ++k) {
                ShadowReq memory s = shadow[(seed >> (7 + k)) % shadow.length];
                if (s.asset != address(tok)) continue;
                rej[nr++] = s.id;
            }
        }
        _call(address(vault), OPERATOR, abi.encodeCall(KpkShares.processRequests, (app, rej, address(tok), price)));
    }

    /// Permissionless recoverAssets sweeps any non-escrowed vault balance to
    /// the portfolio Safe (only fires when the escrow book is empty).
    function recoverAction(uint256 idx) external {
        _tick(idx);
        address[] memory list = new address[](3);
        list[0] = address(assets[0]);
        list[1] = address(assets[1]);
        list[2] = address(assets[2]);
        _call(address(vault), actors[idx % N_ACTORS], abi.encodeWithSelector(RECOVER, list));
    }

    /// Operator toggles deposit/redeem flags (and occasionally attempts a
    /// removal, which the pending-request gate usually reverts).
    function updateAssetAction(uint256 idx, uint256 seed) external {
        _tick(seed);
        MockERC20 tok = assets[1 + idx % 2]; // keep the base asset stable
        uint256 m = seed % 4;
        if (m == 0) {
            _call(address(vault), OPERATOR, abi.encodeCall(KpkShares.updateAsset, (address(tok), false, true, true)));
        } else if (m == 1) {
            _call(address(vault), OPERATOR, abi.encodeCall(KpkShares.updateAsset, (address(tok), false, true, false)));
        } else if (m == 2) {
            _call(address(vault), OPERATOR, abi.encodeCall(KpkShares.updateAsset, (address(tok), false, false, true)));
        } else {
            _call(address(vault), OPERATOR, abi.encodeCall(KpkShares.updateAsset, (address(tok), false, false, false)));
        }
    }

    /// Admin config setters: TTLs, fee rates, fee receiver, perf module.
    function setterAction(uint256 idx, uint256 seed) external {
        _tick(seed);
        uint256 m = seed % 7;
        if (m == 0) {
            _call(address(vault), ADMIN, abi.encodeCall(KpkShares.setSubscriptionRequestTtl, (uint64(_bound(seed >> 3, 1 hours, 7 days)))));
        } else if (m == 1) {
            _call(address(vault), ADMIN, abi.encodeCall(KpkShares.setRedemptionRequestTtl, (uint64(_bound(seed >> 3, 1 hours, 7 days)))));
        } else if (m == 2) {
            _call(address(vault), ADMIN, abi.encodeCall(KpkShares.setFeeReceiver, (idx % 2 == 0 ? FEE_RECEIVER_A : FEE_RECEIVER_B)));
        } else if (m == 3) {
            _call(address(vault), ADMIN, abi.encodeCall(KpkShares.setManagementFeeRate, (_bound(seed >> 3, 0, 2000))));
        } else if (m == 4) {
            _call(address(vault), ADMIN, abi.encodeCall(KpkShares.setRedemptionFeeRate, (_bound(seed >> 3, 0, 2000))));
        } else if (m == 5) {
            _call(address(vault), ADMIN, abi.encodeCall(KpkShares.setPerformanceFeeRate, (_bound(seed >> 3, 0, 2000), address(assets[0]))));
        } else {
            _call(address(vault), ADMIN, abi.encodeCall(KpkShares.setPerformanceFeeModule, (idx % 2 == 0 ? address(perfModule) : address(0))));
        }
    }

    /// Advance time without routing a call (drives fee accrual and expiry).
    function warp(uint256 amount) external {
        VM.warp(block.timestamp + _bound(amount, 0, 365 days));
    }

    /* ============================= INVARIANT CHECKS ============================= */

    /// The share token is conserved exactly: totalSupply equals the sum of the
    /// redemption escrow at the vault, the two fee-receiver balances and every
    /// actor balance. No other address can ever hold shares.
    function checkShareBook() external view returns (bool) {
        uint256 total = vault.totalSupply();
        uint256 sum = vault.balanceOf(address(vault)) + vault.balanceOf(FEE_RECEIVER_A) + vault.balanceOf(FEE_RECEIVER_B);
        for (uint256 i = 0; i < N_ACTORS; ++i) {
            sum += vault.balanceOf(actors[i]);
        }
        return total == sum;
    }

    /// For every asset the escrow book is exact: the vault's balance of the
    /// asset equals the pending-subscription escrow counter.
    function checkAssetEscrow() external view returns (bool) {
        for (uint256 i = 0; i < 3; ++i) {
            if (assets[i].balanceOf(address(vault)) != vault.subscriptionAssets(address(assets[i]))) {
                return false;
            }
        }
        return true;
    }

    /// Decimal string for a uint256 (diagnostics in invariant failure messages).
    function uint2str(uint256 v) external pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory buf = new bytes(78);
        uint256 i = 78;
        while (v > 0) {
            i -= 1;
            buf[i] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        bytes memory out = new bytes(78 - i);
        for (uint256 j = 0; j < out.length; ++j) out[j] = buf[i + j];
        return string(out);
    }
}
