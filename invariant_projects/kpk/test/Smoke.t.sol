// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./KpkHandler.sol";
import {IkpkShares} from "../src/IkpkShares.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Deterministic smoke tests over the kpk KpkShares harness. No
/// forge-std dependency, matching the balancer-v2 / compound-v3 / monolith
/// playbook. Tests drive the real protocol directly with pranked actors so
/// the exact share book, the per-asset escrow, fee settlement, TTL/expiry and
/// the permission guards can be pinned precisely.
contract KpkSmokeTests {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    KpkHandler internal h;
    KpkShares internal vault;
    MockERC20 internal base;
    MockERC20 internal alt;
    MockERC20 internal spare;

    constructor() {
        h = new KpkHandler();
        vault = h.vault();
        base = h.assets(0);
        alt = h.assets(1);
        spare = h.assets(2);
    }

    function _prank(address who) internal {
        VM.startPrank(who);
    }

    function _unprank() internal {
        VM.stopPrank();
    }

    /// subscribe (escrow) -> operator approve (mint + move to Safe) round-trips
    /// exactly. 1M USDC at $1/share mints 1e24 shares and moves 1e12 units to
    /// the portfolio Safe.
    function test_subscription_approve_roundtrip() public {
        address alice = h.actors(0);
        _prank(alice);
        uint256 id = vault.requestSubscription(1_000_000e6, 1e18, address(base), alice);
        _unprank();

        require(vault.requestId() == id, "request id");
        require(base.balanceOf(address(vault)) == 1_000_000e6, "escrow not pulled in");
        require(vault.subscriptionAssets(address(base)) == 1_000_000e6, "escrow book not credited");

        _prank(h.OPERATOR());
        vault.processRequests(_single(id), new uint256[](0), address(base), 1e8);
        _unprank();

        require(vault.balanceOf(alice) == 1e24, "shares not minted");
        require(base.balanceOf(address(vault)) == 0, "escrow not cleared");
        require(vault.subscriptionAssets(address(base)) == 0, "escrow book not debited");
        require(base.balanceOf(h.SAFE()) == h.SAFE_PREFUND_6() + 1_000_000e6, "assets not moved to safe");
        require(h.checkShareBook() && h.checkAssetEscrow(), "ledger broken after subscription");
    }

    /// redeem (escrow shares) -> operator approve (burn net shares, pay 1%
    /// fee to the fee receiver, pull assets from the Safe) round-trips exactly.
    function test_redemption_roundtrip() public {
        address alice = h.actors(0);
        _prank(alice);
        uint256 subId = vault.requestSubscription(1_000_000e6, 1e18, address(base), alice);
        _unprank();
        _prank(h.OPERATOR());
        vault.processRequests(_single(subId), new uint256[](0), address(base), 1e8);
        _unprank();

        _prank(alice);
        uint256 redId = vault.requestRedemption(1e24, 990_000e6, address(base), alice);
        _unprank();
        require(vault.balanceOf(address(vault)) == 1e24, "shares not escrowed");

        _prank(h.OPERATOR());
        vault.processRequests(_single(redId), new uint256[](0), address(base), 1e8);
        _unprank();

        // 1% redemption fee = 1e22 shares -> fee receiver; 9.9e23 burned;
        // alice receives 990000 USDC from the Safe (no time has passed, so no
        // management/performance fee accrues).
        require(vault.balanceOf(h.FEE_RECEIVER_A()) == 1e22, "redemption fee not paid");
        require(vault.balanceOf(address(vault)) == 0, "escrow not burned");
        require(vault.balanceOf(alice) == 0, "alice shares not burned");
        require(base.balanceOf(alice) == 990_000e6, "assets not paid to receiver");
        require(vault.totalSupply() == 1e22, "supply wrong after fee");
        require(h.checkShareBook() && h.checkAssetEscrow(), "ledger broken after redemption");
    }

    /// Multi-asset subscription at the alt price: 3 WETH at $3000 maps to
    /// shares = amount * 1e26/(price * 10^18) = 3e18*1e26/3e29 = 1e15 shares.
    function test_alt_asset_subscription() public {
        address alice = h.actors(0);
        _prank(alice);
        uint256 id = vault.requestSubscription(3e18, 1e15, address(alt), alice);
        _unprank();
        _prank(h.OPERATOR());
        vault.processRequests(_single(id), new uint256[](0), address(alt), 3000e8);
        _unprank();
        require(vault.balanceOf(alice) == 1e15, "alt shares wrong");
        require(alt.balanceOf(h.SAFE()) == h.SAFE_PREFUND_18() + 3e18, "alt not moved to safe");
        require(h.checkShareBook() && h.checkAssetEscrow(), "ledger broken");
    }

    /// A subscription request is cancellable only after the TTL; cancelling
    /// returns the exact escrowed assets to the investor and zeroes the book.
    function test_cancel_subscription_after_ttl() public {
        address alice = h.actors(0);
        _prank(alice);
        uint256 id = vault.requestSubscription(100_000e6, 1e16, address(base), alice);
        _unprank();

        VM.warp(block.timestamp + 1 days + 1);

        _prank(alice);
        vault.cancelSubscription(id);
        _unprank();

        require(vault.getRequest(id).requestStatus == IkpkShares.RequestStatus.CANCELLED, "not cancelled");
        require(base.balanceOf(alice) == h.PREFUND_6(), "assets not returned");
        require(base.balanceOf(address(vault)) == 0, "escrow not returned");
        require(vault.subscriptionAssets(address(base)) == 0, "escrow book not zeroed");
        require(h.checkShareBook() && h.checkAssetEscrow(), "ledger broken after cancel");
    }

    /// A redemption request cancelled after its TTL returns the escrowed
    /// shares to the investor.
    function test_cancel_redemption_after_ttl() public {
        address alice = h.actors(0);
        _prank(alice);
        uint256 subId = vault.requestSubscription(1_000_000e6, 1e18, address(base), alice);
        _unprank();
        _prank(h.OPERATOR());
        vault.processRequests(_single(subId), new uint256[](0), address(base), 1e8);
        _unprank();

        _prank(alice);
        uint256 redId = vault.requestRedemption(1e24, 990_000e6, address(base), alice);
        _unprank();

        VM.warp(block.timestamp + 1 days + 1);

        _prank(alice);
        vault.cancelRedemption(redId);
        _unprank();

        require(vault.getRequest(redId).requestStatus == IkpkShares.RequestStatus.CANCELLED, "not cancelled");
        require(vault.balanceOf(alice) == 1e24, "shares not returned");
        require(vault.balanceOf(address(vault)) == 0, "escrow not returned");
        require(h.checkShareBook() && h.checkAssetEscrow(), "ledger broken after redemption cancel");
    }

    /// An unprocessed request past MAX_TTL (7 days) is auto-rejected on
    /// processing and the assets are returned to the investor.
    function test_expired_request_auto_rejects() public {
        address alice = h.actors(0);
        _prank(alice);
        uint256 id = vault.requestSubscription(100_000e6, 1e16, address(base), alice);
        _unprank();

        VM.warp(block.timestamp + 8 days);

        _prank(h.OPERATOR());
        vault.processRequests(_single(id), new uint256[](0), address(base), 1e8);
        _unprank();

        require(vault.getRequest(id).requestStatus == IkpkShares.RequestStatus.REJECTED, "not rejected");
        require(base.balanceOf(alice) == h.PREFUND_6(), "assets not returned on expiry");
        require(base.balanceOf(address(vault)) == 0, "escrow not cleared");
        require(h.checkShareBook() && h.checkAssetEscrow(), "ledger broken after expiry");
    }

    /// Management (5%) + performance (2%) fees accrue after > 6h and mint
    /// exactly 5e22 + 2e22 shares to the fee receiver after one year.
    function test_management_and_performance_fees() public {
        address alice = h.actors(0);
        _prank(alice);
        uint256 subId = vault.requestSubscription(1_000_000e6, 1e18, address(base), alice);
        _unprank();
        _prank(h.OPERATOR());
        vault.processRequests(_single(subId), new uint256[](0), address(base), 1e8);
        _unprank();
        require(vault.totalSupply() == 1e24, "supply before fees");

        VM.warp(block.timestamp + 365 days);

        _prank(h.OPERATOR());
        vault.processRequests(new uint256[](0), new uint256[](0), address(base), 1e8);
        _unprank();

        require(vault.balanceOf(h.FEE_RECEIVER_A()) == 7e22, "fee receiver not paid");
        require(vault.totalSupply() == 1.07e24, "supply wrong after fees");
        require(h.checkShareBook() && h.checkAssetEscrow(), "ledger broken after fees");
    }

    /// recoverAssets sweeps non-escrowed stray balances to the Safe, and is
    /// blocked while a subscription is pending (escrow book stays intact).
    function test_recover_assets() public {
        base.mint(address(vault), 1234e6);
        _prank(h.actors(1));
        address[] memory list = new address[](3);
        list[0] = address(base);
        list[1] = address(alt);
        list[2] = address(spare);
        vault.recoverAssets(list);
        _unprank();

        require(base.balanceOf(h.SAFE()) == h.SAFE_PREFUND_6() + 1234e6, "stray not swept");
        require(base.balanceOf(address(vault)) == 0, "vault not cleaned");
        require(h.checkShareBook() && h.checkAssetEscrow(), "ledger broken after recover");

        // While a subscription is pending the recoverable amount is 0.
        address alice = h.actors(0);
        _prank(alice);
        uint256 id = vault.requestSubscription(100_000e6, 1e16, address(base), alice);
        _unprank();
        _prank(h.actors(1));
        vault.recoverAssets(list);
        _unprank();
        require(base.balanceOf(address(vault)) == 100_000e6, "escrow swept");
        require(h.checkShareBook() && h.checkAssetEscrow(), "ledger broken after blocked recover");
        require(vault.getRequest(id).requestStatus == IkpkShares.RequestStatus.PENDING, "request state");
    }

    /// Pricing round-trips are non-increasing under Floor rounding, and the
    /// $1/1e6-USDC baseline maps exactly to 1e18 shares.
    function test_pricing_math() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e6;
        amounts[1] = 1e12;
        amounts[2] = 1e18;
        uint256[] memory prices = new uint256[](3);
        prices[0] = 1e8;
        prices[1] = 3e8;
        prices[2] = 3000e8;

        for (uint256 p = 0; p < 3; ++p) {
            for (uint256 i = 0; i < 3; ++i) {
                uint256 s = vault.assetsToShares(amounts[i], prices[p], address(base));
                require(vault.sharesToAssets(s, prices[p], address(base)) <= amounts[i], "assets->shares->assets overflow");
                uint256 a = vault.sharesToAssets(amounts[i], prices[p], address(base));
                require(vault.assetsToShares(a, prices[p], address(base)) <= amounts[i], "shares->assets->shares overflow");
            }
        }
        require(vault.assetsToShares(1e12, 1e8, address(base)) == 1e24, "baseline mapping wrong");
    }

    /// Permission and argument guards.
    function test_guards() public {
        address alice = h.actors(0);
        address mallory = h.actors(5);

        // non-operator cannot process requests
        _prank(mallory);
        VM.expectRevert(abi.encodeWithSelector(IkpkShares.NotAuthorized.selector));
        vault.processRequests(new uint256[](0), new uint256[](0), address(base), 1e8);
        _unprank();

        // non-admin cannot set fees
        _prank(mallory);
        VM.expectRevert(abi.encodeWithSelector(IkpkShares.NotAuthorized.selector));
        vault.setManagementFeeRate(100);
        _unprank();

        // zero-amount subscription reverts
        _prank(alice);
        VM.expectRevert(abi.encodeWithSelector(IkpkShares.InvalidArguments.selector));
        vault.requestSubscription(0, 1e16, address(base), alice);
        _unprank();

        // subscription on a non-approved asset reverts
        MockERC20 rogue = new MockERC20("Rogue", "RGE", 18);
        _prank(alice);
        VM.expectRevert(abi.encodeWithSelector(IkpkShares.NotAnApprovedAsset.selector));
        vault.requestSubscription(1e18, 1, address(rogue), alice);
        _unprank();

        // cancellation before TTL reverts
        _prank(alice);
        uint256 id = vault.requestSubscription(100_000e6, 1e16, address(base), alice);
        _unprank();
        _prank(alice);
        VM.expectRevert(abi.encodeWithSelector(IkpkShares.RequestNotPastTtl.selector));
        vault.cancelSubscription(id);
        _unprank();

        // min-shares bound enforced at approval: a 1e5-USDC subscription with
        // an absurd 1e30 min-shares bound cannot clear at any sane price
        _prank(alice);
        uint256 loose = vault.requestSubscription(100_000e6, 1e30, address(base), alice);
        _unprank();
        _prank(h.OPERATOR());
        VM.expectRevert(abi.encodeWithSelector(IkpkShares.RequestPriceLowerThanOperatorPrice.selector));
        vault.processRequests(_single(loose), new uint256[](0), address(base), 1e8);
        _unprank();

        // settle the price first, then a 50% move breaks the deviation band
        _prank(h.OPERATOR());
        vault.processRequests(new uint256[](0), new uint256[](0), address(base), 1e8);
        VM.expectRevert(abi.encodeWithSelector(IkpkShares.PriceDeviationTooLarge.selector));
        vault.processRequests(new uint256[](0), new uint256[](0), address(base), 1.5e8);
        _unprank();

        // fee rates above MAX_FEE_RATE (2000) revert; zero-address fee receiver
        // and zero TTL revert
        _prank(h.ADMIN());
        VM.expectRevert(abi.encodeWithSelector(IkpkShares.FeeRateLimitExceeded.selector));
        vault.setManagementFeeRate(2001);
        VM.expectRevert(abi.encodeWithSelector(IkpkShares.InvalidArguments.selector));
        vault.setFeeReceiver(address(0));
        VM.expectRevert(abi.encodeWithSelector(IkpkShares.InvalidArguments.selector));
        vault.setSubscriptionRequestTtl(0);
        _unprank();
    }

    function _single(uint256 id) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = id;
    }
}
