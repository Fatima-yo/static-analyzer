// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;
pragma abicoder v2;

import "./RocketHandler.sol";

/// @notice Invariant suite for Rocket Pool's RocketTokenRETH. The fuzzer drives
/// only the handler (raw StdInvariant ABI, no forge-std dependency), so every
/// state mutation flows through the real rETH contract with a real pranked
/// user. The oracle mock only ever receives honest reports; therefore a failure
/// of invariant_rethFullyBacked is attributable to the contract's own accounting.
contract RocketInvariants {
    RocketHandler internal h;
    function getH() external view returns (RocketHandler) { return h; }

    address[] internal _targetedContracts;
    address[] internal _targetedSenders;

    constructor() public {
        h = new RocketHandler();
        _targetedContracts.push(address(h));
        for (uint256 i = 0; i < 8; ++i) {
            _targetedSenders.push(h.actors(i));
        }
    }

    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    function targetSelectors() public view returns (FuzzSelector[] memory targetedSelectors) {
        targetedSelectors = new FuzzSelector[](1);
        targetedSelectors[0].addr = address(h);
        targetedSelectors[0].selectors = new bytes4[](2);
        targetedSelectors[0].selectors[0] = h.deposit.selector;
        targetedSelectors[0].selectors[1] = h.burn.selector;
    }

    function targetContracts() public view returns (address[] memory) {
        return _targetedContracts;
    }

    function targetSenders() public view returns (address[] memory) {
        return _targetedSenders;
    }

    /// rETH must always be fully backed: the ETH value of the whole supply
    /// (at the reported exchange rate) can never exceed the real ETH backing
    /// (rETH contract + deposit pool + staking).
    function invariant_rethFullyBacked() public view {
        require(h.checkBacking(), "VIOLATION: rETH not fully backed");
    }

    /// The reported collateral rate (rETH contract ETH / rETH value) can never
    /// exceed 100%, i.e. the contract never claims more collateral than backing.
    function invariant_collateralRateBounded() public view {
        require(h.checkCollateralRate(), "VIOLATION: collateral rate > 100%");
    }

    /// ETH is conserved: deposits, mints, burns, staking and excess-collateral
    /// flows are all internal to the model.
    function invariant_ethConserved() public view {
        if (!h.checkEthConservation()) {
            revert(breakdownString());
        }
    }

    function breakdownString() internal view returns (string memory) {
        (uint256 sum, uint256 constant_, uint256 actorSum, uint256 handler, uint256 rethBal, uint256 poolBal, uint256 validatorBal) = h.conservationBreakdown();
        uint256[8] memory bals = h.actorBalances();
        string memory s = string(abi.encodePacked(
            "VIOLATION sum=", uintToString(sum),
            " const=", uintToString(constant_),
            " actors=", uintToString(actorSum),
            " handler=", uintToString(handler),
            " reth=", uintToString(rethBal),
            " pool=", uintToString(poolBal),
            " validator=", uintToString(validatorBal),
            " selftest=", uintToString(address(this).balance)
        ));
        for (uint256 i = 0; i < 8; ++i) {
            s = string(abi.encodePacked(s, " a", uintToString(i), "=", uintToString(bals[i])));
        }
        return s;
    }

    function uintToString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 n = v;
        uint256 len;
        while (n != 0) { n /= 10; len++; }
        bytes memory b = new bytes(len);
        n = v;
        uint256 i = len;
        while (n != 0) { i--; b[i] = bytes1(uint8(48 + n % 10)); n /= 10; }
        return string(b);
    }

    /// rETH is a standard ERC20: total supply always equals the sum of all
    /// holder balances.
    function invariant_rethSupplyConserved() public view {
        require(h.checkRethSupply(), "VIOLATION: rETH supply != sum of balances");
    }
}
