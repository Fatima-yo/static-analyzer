// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.15;

import "../core/CometCore.sol";

/// @notice Mock asset list: stores the asset configs and derives the
/// per-asset info (offset = index, scale = 10^decimals) on demand, matching
/// the deployed Comet AssetList behavior.
contract MockAssetList {
    CometCore.AssetConfig[] public assetConfigs;

    constructor(CometCore.AssetConfig[] memory assetConfigs_) {
        assetConfigs = assetConfigs_;
    }

    function numAssets() external view returns (uint8) {
        return uint8(assetConfigs.length);
    }

    function getAssetInfo(uint8 i) external view returns (CometCore.AssetInfo memory) {
        CometCore.AssetConfig memory c = assetConfigs[i];
        return CometCore.AssetInfo({
            offset: i,
            asset: c.asset,
            priceFeed: c.priceFeed,
            scale: uint64(10 ** c.decimals),
            borrowCollateralFactor: c.borrowCollateralFactor,
            liquidateCollateralFactor: c.liquidateCollateralFactor,
            liquidationFactor: c.liquidationFactor,
            supplyCap: c.supplyCap
        });
    }
}
