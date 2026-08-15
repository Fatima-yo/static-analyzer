// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "../src/vault/Vault.sol";
import "../src/vault/interfaces/IWETH.sol";
import "../src/vault/interfaces/IFlashLoanRecipient.sol";
import "../src/lib/openzeppelin/IERC20.sol";

import "./MockERC20.sol";
import "./MockAuthorizer.sol";
import "./MockPool.sol";
import "./FlashLoanRecipient.sol";

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert(bytes calldata) external;
}

/// @notice Invariant harness for Balancer V2's Vault (Ethereum 0xba1..., solc
/// 0.7.6). A pure-ERC20 system: three MockERC20 tokens, two constant-product
/// MINIMAL_SWAP_INFO mock pools (A-B and B-C), and eight actors. Every action
/// is routed through `vm.prank(actor)` so the Vault sees a real user with
/// real token balances; no value cheatcodes are used. Actions cover the swap,
/// join/exit, flash loan and internal-balance surfaces, which is exactly where
/// the run3 guarded-subtraction flags live (FlashLoans:77, PoolBalances:242/243,
/// AssetTransfersHandler:72/131, Swaps:411/412, UserBalance:193).
contract BalancerHandler {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint256 public constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 public constant ACTOR_MINT = 100_000 ether;

    Vault public vault;
    MockERC20[3] public tokens;
    MockPool[2] public pools;
    FlashLoanRecipient[3] public loanRecipients;
    address payable[8] public actors;

    constructor() {
        MockAuthorizer authorizer = new MockAuthorizer();
        vault = new Vault(IAuthorizer(address(authorizer)), IWETH(address(0)), 0, 0);

        tokens[0] = new MockERC20("Token A", "A");
        tokens[1] = new MockERC20("Token B", "B");
        tokens[2] = new MockERC20("Token C", "C");

        for (uint256 i = 0; i < 3; ++i) {
            tokens[i].mint(address(this), INITIAL_SUPPLY);
        }

        actors[0] = 0x1111000000000000000000000000000000000001;
        actors[1] = 0x1111000000000000000000000000000000000002;
        actors[2] = 0x1111000000000000000000000000000000000003;
        actors[3] = 0x1111000000000000000000000000000000000004;
        actors[4] = 0x1111000000000000000000000000000000000005;
        actors[5] = 0x1111000000000000000000000000000000000006;
        actors[6] = 0x1111000000000000000000000000000000000007;
        actors[7] = 0x1111000000000000000000000000000000000008;

        for (uint256 i = 0; i < 8; ++i) {
            address actor = actors[i];
            for (uint256 j = 0; j < 3; ++j) {
                tokens[j].transfer(actor, ACTOR_MINT);
            }
            VM.startPrank(actor);
            for (uint256 j = 0; j < 3; ++j) {
                tokens[j].approve(address(vault), uint256(-1));
            }
            VM.stopPrank();
        }

        pools[0] = new MockPool(vault, IERC20(address(tokens[0])), IERC20(address(tokens[1])));
        pools[1] = new MockPool(vault, IERC20(address(tokens[1])), IERC20(address(tokens[2])));

        loanRecipients[0] = new FlashLoanRecipient(0);
        loanRecipients[1] = new FlashLoanRecipient(1);
        loanRecipients[2] = new FlashLoanRecipient(2);
    }

    // ---------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------

    function swapGivenIn(
        uint8 poolIdx,
        uint8 actorIdx,
        uint8 tokenInIdx,
        uint8 tokenOutIdx,
        uint256 amount
    ) public {
        if (poolIdx >= 2 || actorIdx >= 8 || tokenInIdx >= 3 || tokenOutIdx >= 3) return;
        if (tokenInIdx == tokenOutIdx) return;
        MockPool pool = pools[poolIdx];
        if (!_poolHasToken(pool, tokenInIdx) || !_poolHasToken(pool, tokenOutIdx)) return;

        address payable actor = actors[actorIdx];
        uint256 inBal = tokens[tokenInIdx].balanceOf(actor);
        if (amount > inBal) amount = inBal;
        if (amount == 0) return;

        IVault.SingleSwap memory s;
        s.poolId = pool.poolId();
        s.kind = IVault.SwapKind.GIVEN_IN;
        s.assetIn = IAsset(address(tokens[tokenInIdx]));
        s.assetOut = IAsset(address(tokens[tokenOutIdx]));
        s.amount = amount;
        s.userData = bytes("");

        IVault.FundManagement memory f;
        f.sender = actor;
        f.fromInternalBalance = false;
        f.recipient = actor;
        f.toInternalBalance = false;

        VM.startPrank(actor);
        vault.swap(s, f, 0, block.timestamp + 1);
        VM.stopPrank();
    }

    function swapGivenOut(
        uint8 poolIdx,
        uint8 actorIdx,
        uint8 tokenInIdx,
        uint8 tokenOutIdx,
        uint256 amount
    ) public {
        if (poolIdx >= 2 || actorIdx >= 8 || tokenInIdx >= 3 || tokenOutIdx >= 3) return;
        if (tokenInIdx == tokenOutIdx) return;
        MockPool pool = pools[poolIdx];
        if (!_poolHasToken(pool, tokenInIdx) || !_poolHasToken(pool, tokenOutIdx)) return;

        address payable actor = actors[actorIdx];
        uint256 outCash = _poolCash(pool, tokenOutIdx);
        if (outCash <= 1) return;
        if (amount > outCash / 4) amount = outCash / 4;
        if (amount == 0) return;

        IVault.SingleSwap memory s;
        s.poolId = pool.poolId();
        s.kind = IVault.SwapKind.GIVEN_OUT;
        s.assetIn = IAsset(address(tokens[tokenInIdx]));
        s.assetOut = IAsset(address(tokens[tokenOutIdx]));
        s.amount = amount;
        s.userData = bytes("");

        IVault.FundManagement memory f;
        f.sender = actor;
        f.fromInternalBalance = false;
        f.recipient = actor;
        f.toInternalBalance = false;

        VM.startPrank(actor);
        vault.swap(s, f, uint256(-1), block.timestamp + 1);
        VM.stopPrank();
    }

    function joinPool(
        uint8 poolIdx,
        uint8 actorIdx,
        uint8 tokenIdx,
        uint256 amount
    ) public {
        if (poolIdx >= 2 || actorIdx >= 8 || tokenIdx >= 3) return;
        MockPool pool = pools[poolIdx];
        if (!_poolHasToken(pool, tokenIdx)) return;

        address payable actor = actors[actorIdx];
        uint256 inBal = tokens[tokenIdx].balanceOf(actor);
        if (amount > inBal) amount = inBal;
        if (amount == 0) return;

        (IAsset[] memory assets, uint256[] memory maxAmountsIn) = _poolAssetsAnd(pool);

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[_poolTokenPos(pool, tokenIdx)] = amount;

        IVault.JoinPoolRequest memory req;
        req.assets = assets;
        req.maxAmountsIn = maxAmountsIn;
        req.userData = abi.encode(amountsIn);
        req.fromInternalBalance = false;

        VM.startPrank(actor);
        vault.joinPool(pool.poolId(), actor, actor, req);
        VM.stopPrank();
    }

    function exitPool(
        uint8 poolIdx,
        uint8 actorIdx,
        uint8 tokenIdx,
        uint256 amount
    ) public {
        if (poolIdx >= 2 || actorIdx >= 8 || tokenIdx >= 3) return;
        MockPool pool = pools[poolIdx];
        if (!_poolHasToken(pool, tokenIdx)) return;

        address payable actor = actors[actorIdx];
        uint256 shares = pool.balanceOf(actor);
        if (amount > shares) amount = shares;

        uint256 cash = _poolCash(pool, tokenIdx);
        if (amount > cash) amount = cash;
        if (amount == 0) return;

        (IAsset[] memory assets, ) = _poolAssetsAnd(pool);

        uint256[] memory amountsOut = new uint256[](2);
        amountsOut[_poolTokenPos(pool, tokenIdx)] = amount;

        uint256[] memory minAmountsOut = new uint256[](2);

        IVault.ExitPoolRequest memory req;
        req.assets = assets;
        req.minAmountsOut = minAmountsOut;
        req.userData = abi.encode(amountsOut);
        req.toInternalBalance = false;

        VM.startPrank(actor);
        vault.exitPool(pool.poolId(), actor, actor, req);
        VM.stopPrank();
    }

    function flashLoan(
        uint8 actorIdx,
        uint8 tokenIdx,
        uint256 amount,
        uint8 mode
    ) public {
        if (actorIdx >= 8 || tokenIdx >= 3) return;
        uint256 vaultBal = tokens[tokenIdx].balanceOf(address(vault));
        if (amount > vaultBal) amount = vaultBal;
        if (amount == 0) return;

        address payable actor = actors[actorIdx];
        IFlashLoanRecipient recipient = loanRecipients[mode % 3];

        IERC20[] memory t = new IERC20[](1);
        t[0] = IERC20(address(tokens[tokenIdx]));
        uint256[] memory a = new uint256[](1);
        a[0] = amount;

        VM.startPrank(actor);
        vault.flashLoan(recipient, t, a, bytes(""));
        VM.stopPrank();
    }

    function depositInternal(
        uint8 actorIdx,
        uint8 tokenIdx,
        uint256 amount
    ) public {
        if (actorIdx >= 8 || tokenIdx >= 3) return;
        address payable actor = actors[actorIdx];
        uint256 inBal = tokens[tokenIdx].balanceOf(actor);
        if (amount > inBal) amount = inBal;
        if (amount == 0) return;

        IVault.UserBalanceOp[] memory ops = _singleInternalOp(
            IVault.UserBalanceOpKind.DEPOSIT_INTERNAL,
            tokenIdx,
            amount,
            actor,
            actor
        );

        VM.startPrank(actor);
        vault.manageUserBalance(ops);
        VM.stopPrank();
    }

    function withdrawInternal(
        uint8 actorIdx,
        uint8 tokenIdx,
        uint256 amount
    ) public {
        if (actorIdx >= 8 || tokenIdx >= 3) return;
        address payable actor = actors[actorIdx];
        uint256 internalBal = _internalBalance(actor, tokenIdx);
        if (amount > internalBal) amount = internalBal;
        if (amount == 0) return;

        IVault.UserBalanceOp[] memory ops = _singleInternalOp(
            IVault.UserBalanceOpKind.WITHDRAW_INTERNAL,
            tokenIdx,
            amount,
            actor,
            actor
        );

        VM.startPrank(actor);
        vault.manageUserBalance(ops);
        VM.stopPrank();
    }

    function transferInternal(
        uint8 fromIdx,
        uint8 toIdx,
        uint8 tokenIdx,
        uint256 amount
    ) public {
        if (fromIdx >= 8 || toIdx >= 8 || tokenIdx >= 3) return;
        address payable from = actors[fromIdx];
        address payable to = actors[toIdx];
        if (from == to) return;

        uint256 internalBal = _internalBalance(from, tokenIdx);
        if (amount > internalBal) amount = internalBal;
        if (amount == 0) return;

        IVault.UserBalanceOp[] memory ops = _singleInternalOp(
            IVault.UserBalanceOpKind.TRANSFER_INTERNAL,
            tokenIdx,
            amount,
            from,
            to
        );

        VM.startPrank(from);
        vault.manageUserBalance(ops);
        VM.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Invariant checks
    // ---------------------------------------------------------------------

    /// @notice No token is ever created or destroyed: handler + vault +
    /// protocol-fees collector + all actors must always sum to INITIAL_SUPPLY.
    function checkTokenConservation(uint8 tokenIdx) external view returns (bool) {
        if (tokenIdx >= 3) return false;
        IERC20 token = IERC20(address(tokens[tokenIdx]));

        uint256 total = token.balanceOf(address(this));
        total += token.balanceOf(address(vault));
        total += token.balanceOf(address(vault.getProtocolFeesCollector()));

        for (uint256 i = 0; i < 8; ++i) {
            total += token.balanceOf(actors[i]);
        }

        return total == INITIAL_SUPPLY;
    }

    /// @notice Vault ledger exactness: the tokens the Vault physically holds
    /// must equal what the pools' virtual cash plus the actors' internal
    /// balances say the Vault is owed. This is the strictest accounting
    /// invariant and catches the swap/join/exit/flashLoan guard paths.
    function checkVaultLedger(uint8 tokenIdx) external view returns (bool) {
        if (tokenIdx >= 3) return false;

        uint256 poolCash = 0;
        for (uint256 i = 0; i < 2; ++i) {
            MockPool pool = pools[i];
            if (address(pool.tokenA()) == address(tokens[tokenIdx]) || address(pool.tokenB()) == address(tokens[tokenIdx])) {
                poolCash += _poolCash(pool, tokenIdx);
            }
        }

        uint256 internalSum = 0;
        for (uint256 i = 0; i < 8; ++i) {
            internalSum += _internalBalance(actors[i], tokenIdx);
        }

        return tokens[tokenIdx].balanceOf(address(vault)) == poolCash + internalSum;
    }

    /// @notice Pool share exactness: minted supply equals the shares held by
    /// the eight actors (only actors ever receive shares).
    function checkPoolShares(uint8 poolIdx) external view returns (bool) {
        if (poolIdx >= 2) return false;
        MockPool pool = pools[poolIdx];

        uint256 sum = 0;
        for (uint256 i = 0; i < 8; ++i) {
            sum += pool.balanceOf(actors[i]);
        }

        return sum == pool.totalSupply();
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _poolHasToken(MockPool pool, uint8 tokenIdx) internal view returns (bool) {
        return address(pool.tokenA()) == address(tokens[tokenIdx]) || address(pool.tokenB()) == address(tokens[tokenIdx]);
    }

    function _poolAssetsAnd(MockPool pool)
        internal
        view
        returns (IAsset[] memory assets, uint256[] memory max)
    {
        (IERC20[] memory registered, , ) = vault.getPoolTokens(pool.poolId());

        assets = new IAsset[](2);
        assets[0] = IAsset(address(registered[0]));
        assets[1] = IAsset(address(registered[1]));

        max = new uint256[](2);
        max[0] = uint256(-1);
        max[1] = uint256(-1);
    }

    function _poolCash(MockPool pool, uint8 tokenIdx) internal view returns (uint256) {
        (, uint256[] memory balances, ) = vault.getPoolTokens(pool.poolId());
        return balances[_poolTokenPos(pool, tokenIdx)];
    }

    function _poolTokenPos(MockPool pool, uint8 tokenIdx) internal view returns (uint8) {
        (IERC20[] memory registered, , ) = vault.getPoolTokens(pool.poolId());
        return address(registered[0]) == address(tokens[tokenIdx]) ? 0 : 1;
    }

    function _internalBalance(address user, uint8 tokenIdx) internal view returns (uint256) {
        IERC20[] memory t = new IERC20[](1);
        t[0] = IERC20(address(tokens[tokenIdx]));
        return vault.getInternalBalance(user, t)[0];
    }

    function _singleInternalOp(
        IVault.UserBalanceOpKind kind,
        uint8 tokenIdx,
        uint256 amount,
        address sender,
        address payable recipient
    ) internal view returns (IVault.UserBalanceOp[] memory ops) {
        ops = new IVault.UserBalanceOp[](1);
        ops[0].kind = kind;
        ops[0].asset = IAsset(address(tokens[tokenIdx]));
        ops[0].amount = amount;
        ops[0].sender = sender;
        ops[0].recipient = recipient;
    }
}
