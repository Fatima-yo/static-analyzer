// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/// @notice Chainlink-style price feed for the monolith-market Lender harness.
/// Settable by the handler to drive liquidations, redemptions and write-offs
/// under price shocks. updatedAt is set by the handler so the Lender's
/// STALENESS_THRESHOLD (25 hours) unwind logic can also be exercised.
contract MockChainlinkFeed {
    uint8 public decimals;
    uint256 public updatedAt;
    int256 public price;

    constructor(uint8 decimals_, int256 price_) {
        decimals = decimals_;
        price = price_;
        updatedAt = block.timestamp;
    }

    function setPrice(int256 price_) external {
        require(price_ > 0, "BadPrice");
        price = price_;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        updatedAt = updatedAt_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt_, uint80 answeredInRound)
    {
        return (1, price, 0, updatedAt, 1);
    }
}
