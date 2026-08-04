// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;

/// @notice Minimal ERC20 token used by the Balancer V2 invariant harness.
/// Simplifies the interface to just the surfaces the Vault and mock pools
/// touch (balanceOf/transfer/transferFrom/approve plus mint/burn helpers).
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "MockERC20: burn exceeds balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != uint256(-1)) {
            require(allowed >= amount, "MockERC20: allowance exceeded");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) private {
        require(balanceOf[from] >= amount, "MockERC20: balance exceeded");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
