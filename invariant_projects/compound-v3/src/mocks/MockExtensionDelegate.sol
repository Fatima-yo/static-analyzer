// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.15;

import "./MockAssetListFactory.sol";

/// @notice Mock extension delegate holder exposing the asset list factory that
/// Comet's constructor requires (`IAssetListFactoryHolder`).
contract MockExtensionDelegate {
    MockAssetListFactory public factory;

    constructor(MockAssetListFactory factory_) {
        factory = factory_;
    }

    function assetListFactory() external view returns (address) {
        return address(factory);
    }
}
