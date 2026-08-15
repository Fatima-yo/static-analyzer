// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.15;

import "../core/IPriceFeed.sol";

/// @notice Mock Chainlink-style price feed (8 decimals, PRICE_FEED_DECIMALS).
/// Settable by the handler to drive liquidation/absorption under price shocks.
contract MockPriceFeed is IPriceFeed {
    uint8 public override decimals = 8;
    string public override description = "mock";
    uint256 public override version = 1;

    int256 public price;

    constructor(int256 price_) {
        price = price_;
    }

    function setPrice(int256 price_) external {
        require(price_ > 0, "BadPrice");
        price = price_;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, price, 0, 1, 1);
    }
}
