// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import { IonicComptroller } from "./compound/ComptrollerInterface.sol";

/// @notice Harness stub for the real PoolLens periphery. CToken only calls
/// `getHealthFactor` to gate non-permissioned liquidations; returning 0 keeps
/// every liquidation permissionless so the fuzzer can reach all seize paths.
contract PoolLens {
  function getHealthFactor(address, IonicComptroller) external pure returns (uint256) {
    return 0;
  }
}
