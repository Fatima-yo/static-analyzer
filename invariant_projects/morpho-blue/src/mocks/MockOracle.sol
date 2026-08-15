// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/// @notice Fixed-price oracle for the morpho-blue harness. The handler is the
/// only caller of `setPrice`; it shocks the price to create under-collateralized
/// positions (liquidation pressure) and restores it immediately after, so the
/// ledger invariants are evaluated at the honest base price. The price is
/// expressed in ORACLE_PRICE_SCALE (1e36) as IOracle requires.
contract MockOracle {
    uint256 public price_;

    constructor(uint256 initialPrice) {
        price_ = initialPrice;
    }

    function price() external view returns (uint256) {
        return price_;
    }

    function setPrice(uint256 newPrice) external {
        price_ = newPrice;
    }
}
