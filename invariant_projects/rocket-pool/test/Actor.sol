// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;

/// @notice Minimal on-chain user for the rocket-pool invariant harness. Each
/// Actor owns real ETH and rETH and routes pool/token calls with itself as
/// `msg.sender`, so every value-bearing operation is an ordinary atomic EVM
/// transfer (no cheatcode-based balance redirection, which is what made the
/// prank-based harness lose ETH under foundry's call_raw + prank+value path).
/// Protocol reverts are bubbled up unchanged so the harness surfaces the real
/// guard messages (deposit delay, liquidity).
contract Actor {
    function _bubble(bool ok, bytes memory data) internal pure {
        if (!ok) {
            if (data.length > 0) {
                assembly {
                    revert(add(data, 32), mload(data))
                }
            }
            revert("actor call failed");
        }
    }

    function deposit(address pool, uint256 amount) external {
        (bool ok, bytes memory data) = pool.call{value: amount}(abi.encodeWithSignature("deposit()"));
        _bubble(ok, data);
    }

    function depositAndMint(address pool, address reth, uint256 amount) external {
        (bool ok, bytes memory data) = pool.call{value: amount}(abi.encodeWithSignature("deposit()"));
        _bubble(ok, data);
        (bool ok2, bytes memory data2) = pool.call(
            abi.encodeWithSignature("mintReth(address,uint256,address)", reth, amount, address(this))
        );
        _bubble(ok2, data2);
    }

    function burn(address reth, uint256 amount) external {
        (bool ok, bytes memory data) = reth.call(abi.encodeWithSignature("burn(uint256)", amount));
        _bubble(ok, data);
    }

    function transfer(address reth, address to, uint256 amount) external {
        (bool ok, bytes memory data) = reth.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        _bubble(ok, data);
    }

    receive() external payable {}
}
