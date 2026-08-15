pragma solidity ^0.5.8;

/// @notice Minimal on-chain user for the compound-v2 invariant harness. Each
/// Actor owns real ETH and routes market calls to the CEther markets with
/// itself as `msg.sender`, so every value-bearing operation is an ordinary
/// atomic EVM transfer (no cheatcode-based balance redirection, which is what
/// made the fuzz harness lose ETH).
contract Actor {
    function mint(address market, uint256 amount) external {
        (bool ok, ) = market.call.value(amount)(abi.encodeWithSignature("mint()"));
        require(ok, "mint failed");
    }

    function redeem(address market, uint256 redeemTokens) external {
        (bool ok, ) = market.call(abi.encodeWithSignature("redeem(uint256)", redeemTokens));
        require(ok, "redeem failed");
    }

    function borrow(address market, uint256 borrowAmount) external {
        (bool ok, ) = market.call(abi.encodeWithSignature("borrow(uint256)", borrowAmount));
        require(ok, "borrow failed");
    }

    function repay(address market, uint256 amount) external {
        (bool ok, ) = market.call.value(amount)(abi.encodeWithSignature("repayBorrow()"));
        require(ok, "repay failed");
    }

    function repayBehalf(address market, address borrower, uint256 amount) external {
        (bool ok, ) = market.call.value(amount)(
                abi.encodeWithSignature("repayBorrowBehalf(address)", borrower)
            );
        require(ok, "repayBehalf failed");
    }

    function liquidate(
        address market,
        address borrower,
        address collateral,
        uint256 amount
    ) external {
        (bool ok, ) = market.call.value(amount)(
                abi.encodeWithSignature("liquidateBorrow(address,address)", borrower, collateral)
            );
        require(ok, "liquidate failed");
    }

    function approve(address market, address spender) external {
        (bool ok, ) = market.call(abi.encodeWithSignature("approve(address,uint256)", spender, uint(-1)));
        require(ok, "approve failed");
    }

    function transfer(address market, address to, uint256 amount) external {
        (bool ok, ) = market.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok, "transfer failed");
    }

    function transferFrom(address market, address from, address to, uint256 amount) external {
        (bool ok, ) = market.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount));
        require(ok, "transferFrom failed");
    }

    function() external payable {}
}
