// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

/// @notice Harness stub for the real IonicUniV3Liquidator periphery. CToken
/// only reads `healthFactorThreshold`; with the PoolLens stub returning 0 the
/// comparison `getHealthFactor > threshold` is always false, so any account
/// may liquidate (permissionless path).
contract IonicUniV3Liquidator {
  uint256 public constant healthFactorThreshold = 0;
}
