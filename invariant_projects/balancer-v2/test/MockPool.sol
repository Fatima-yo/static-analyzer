// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "../src/vault/interfaces/IVault.sol";
import "../src/vault/interfaces/IMinimalSwapInfoPool.sol";
import "../src/vault/interfaces/IPoolSwapStructs.sol";
import "../src/lib/openzeppelin/IERC20.sol";

/// @notice Minimal-swap-info constant-product mock pool used by the Balancer
/// V2 invariant harness. Keeps accounting arithmetic trivial (no swap fees,
/// no protocol fees, shares minted/burned 1:1 with tokens in/out) so that any
/// ledger mismatch must come from the Vault, not from pool math.
contract MockPool is IMinimalSwapInfoPool {
    IVault public immutable vault;
    bytes32 public immutable poolId;
    IERC20 public immutable tokenA;
    IERC20 public immutable tokenB;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(
        IVault vault_,
        IERC20 tokenA_,
        IERC20 tokenB_
    ) {
        vault = vault_;
        tokenA = tokenA_;
        tokenB = tokenB_;

        bytes32 newPoolId = vault_.registerPool(IVault.PoolSpecialization.MINIMAL_SWAP_INFO);
        poolId = newPoolId;

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = tokenA_;
        tokens[1] = tokenB_;

        address[] memory managers = new address[](2);
        vault_.registerTokens(newPoolId, tokens, managers);
    }

    function onSwap(
        IPoolSwapStructs.SwapRequest memory request,
        uint256 balanceTokenIn,
        uint256 balanceTokenOut
    ) external override returns (uint256 amount) {
        require(msg.sender == address(vault), "MockPool: only vault");
        require(request.tokenIn == tokenA || request.tokenIn == tokenB, "MockPool: bad tokenIn");
        require(request.tokenOut == tokenA || request.tokenOut == tokenB, "MockPool: bad tokenOut");

        if (request.amount == 0) {
            return 0;
        }

        if (request.kind == IVault.SwapKind.GIVEN_IN) {
            require(balanceTokenIn > 0 && balanceTokenOut > 0, "MockPool: empty pool");
            return (balanceTokenOut * request.amount) / (balanceTokenIn + request.amount);
        } else {
            require(balanceTokenIn > 0 && balanceTokenOut > request.amount, "MockPool: empty pool");
            return (balanceTokenIn * request.amount) / (balanceTokenOut - request.amount);
        }
    }

    function onJoinPool(
        bytes32,
        address,
        address recipient,
        uint256[] memory balances,
        uint256,
        uint256,
        bytes memory userData
    )
        external
        override
        returns (uint256[] memory amountsIn, uint256[] memory dueProtocolFeeAmounts)
    {
        require(msg.sender == address(vault), "MockPool: only vault");

        amountsIn = abi.decode(userData, (uint256[]));
        require(amountsIn.length == balances.length, "MockPool: bad join data");
        dueProtocolFeeAmounts = new uint256[](balances.length);

        uint256 minted = 0;
        for (uint256 i = 0; i < amountsIn.length; ++i) {
            minted += amountsIn[i];
        }
        if (minted > 0) {
            totalSupply += minted;
            balanceOf[recipient] += minted;
        }
    }

    function onExitPool(
        bytes32,
        address sender,
        address,
        uint256[] memory balances,
        uint256,
        uint256,
        bytes memory userData
    )
        external
        override
        returns (uint256[] memory amountsOut, uint256[] memory dueProtocolFeeAmounts)
    {
        require(msg.sender == address(vault), "MockPool: only vault");

        amountsOut = abi.decode(userData, (uint256[]));
        require(amountsOut.length == balances.length, "MockPool: bad exit data");
        dueProtocolFeeAmounts = new uint256[](balances.length);

        uint256 burned = 0;
        for (uint256 i = 0; i < amountsOut.length; ++i) {
            burned += amountsOut[i];
        }
        require(balanceOf[sender] >= burned, "MockPool: insufficient shares");
        balanceOf[sender] -= burned;
        totalSupply -= burned;
    }
}
