// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.7.6;

import "../src/contract/interface/dao/protocol/settings/RocketDAOProtocolSettingsNetworkInterface.sol";

/// @notice Network settings mock. Only getTargetRethCollateralRate() is read by
/// RocketTokenRETH (in depositExcessCollateral); the rest return constants so
/// the vendored interface links.
contract MockDAOProtocolSettingsNetwork is RocketDAOProtocolSettingsNetworkInterface {
    uint256 internal immutable targetRethCollateralRate;

    constructor(uint256 _targetRethCollateralRate) {
        targetRethCollateralRate = _targetRethCollateralRate;
    }

    function getTargetRethCollateralRate() external view override returns (uint256) {
        return targetRethCollateralRate;
    }

    function getNodeConsensusThreshold() external pure override returns (uint256) {
        return 1;
    }

    function getSubmitBalancesEnabled() external pure override returns (bool) {
        return true;
    }

    function getSubmitBalancesFrequency() external pure override returns (uint256) {
        return 1;
    }

    function getSubmitPricesEnabled() external pure override returns (bool) {
        return true;
    }

    function getSubmitPricesFrequency() external pure override returns (uint256) {
        return 1;
    }

    function getMinimumNodeFee() external pure override returns (uint256) {
        return 0;
    }

    function getTargetNodeFee() external pure override returns (uint256) {
        return 0;
    }

    function getMaximumNodeFee() external pure override returns (uint256) {
        return 0;
    }

    function getNodeFeeDemandRange() external pure override returns (uint256) {
        return 0;
    }

    function getRethDepositDelay() external pure override returns (uint256) {
        return 0;
    }
}
