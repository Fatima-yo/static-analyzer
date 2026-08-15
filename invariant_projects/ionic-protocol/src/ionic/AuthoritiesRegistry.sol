// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

/// @notice Harness stub for the real AuthoritiesRegistry. IFeeDistributor only
/// references this type as a return value, so an empty contract satisfies the
/// compiler without pulling in PoolRolesAuthority + the OZ proxy stack.
contract AuthoritiesRegistry {}
