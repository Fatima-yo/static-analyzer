// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

/// @notice Minimal on-chain user for the Ionic invariant harness. Each Actor
/// routes market calls to the CErc20Delegator diamond with itself as
/// `msg.sender`, so every value-bearing operation is an ordinary atomic EVM
/// transfer. Function calls go through the delegator's fallback, which
/// dispatches to the registered logic extensions.
contract Actor {
    function mint(address market, uint256 amount) external {
        (bool ok, ) = market.call(abi.encodeWithSignature("mint(uint256)", amount));
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
        (bool ok, ) = market.call(abi.encodeWithSignature("repayBorrow(uint256)", amount));
        require(ok, "repay failed");
    }

    function repayBehalf(address market, address borrower, uint256 amount) external {
        (bool ok, ) = market.call(abi.encodeWithSignature("repayBorrowBehalf(address,uint256)", borrower, amount));
        require(ok, "repayBehalf failed");
    }

    function liquidate(address market, address borrower, address collateral, uint256 amount) external {
        (bool ok, ) = market.call(
            abi.encodeWithSignature("liquidateBorrow(address,uint256,address)", borrower, amount, collateral)
        );
        require(ok, "liquidate failed");
    }

    function transfer(address market, address to, uint256 amount) external {
        (bool ok, ) = market.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok, "transfer failed");
    }

    function approveUnderlying(address underlying, address market) external {
        (bool ok, ) = underlying.call(
            abi.encodeWithSignature("approve(address,uint256)", market, type(uint256).max)
        );
        require(ok, "approve failed");
    }
}
