// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.15;

import "../core/CometCore.sol";
import "./MockAssetList.sol";

/// @notice Mock asset list factory, deployed via the extension delegate holder.
contract MockAssetListFactory {
    function createAssetList(CometCore.AssetConfig[] memory assetConfigs) external returns (address assetList) {
        assetList = address(new MockAssetList(assetConfigs));
    }
}
