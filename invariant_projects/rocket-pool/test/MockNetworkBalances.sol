// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.7.6;

import "../src/contract/interface/network/RocketNetworkBalancesInterface.sol";

/// @notice RocketNetworkBalances mock. Stores the last oracle report. The
/// handler only ever submits *honest* values (real backing ETH, real staking,
/// real rETH supply), so any invariant break is attributable to the contract
/// code itself rather than to oracle manipulation.
contract MockNetworkBalances is RocketNetworkBalancesInterface {
    uint256 internal balancesBlock;
    uint256 internal totalEthBalance;
    uint256 internal stakingEthBalance;
    uint256 internal rethSupply;

    function getBalancesBlock() external view override returns (uint256) {
        return balancesBlock;
    }

    function getLatestReportableBlock() external view override returns (uint256) {
        return balancesBlock;
    }

    function getTotalETHBalance() external view override returns (uint256) {
        return totalEthBalance;
    }

    function getStakingETHBalance() external view override returns (uint256) {
        return stakingEthBalance;
    }

    function getTotalRETHSupply() external view override returns (uint256) {
        return rethSupply;
    }

    function getETHUtilizationRate() external view override returns (uint256) {
        if (totalEthBalance == 0) {
            return 0;
        }
        return stakingEthBalance * 1 ether / totalEthBalance;
    }

    function submitBalances(uint256 _block, uint256 _total, uint256 _staking, uint256 _rethSupply) external override {
        balancesBlock = _block;
        totalEthBalance = _total;
        stakingEthBalance = _staking;
        rethSupply = _rethSupply;
    }

    function executeUpdateBalances(uint256 _block, uint256 _totalEth, uint256 _stakingEth, uint256 _rethSupply) external override {
        this.submitBalances(_block, _totalEth, _stakingEth, _rethSupply);
    }
}
