// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;

import "../src/vault/interfaces/IAuthorizer.sol";
import "../src/vault/interfaces/IVault.sol";

/// @notice Permissive authorizer for the Balancer V2 invariant harness.
/// Returns true for every action so the harness can exercise the full Vault
/// surface (pause, relayer approval, asset manager config, fees, pool
/// registration) without governing restrictions. The only caller of
/// `canPerform` is the Vault itself (the `where` argument), which is also
/// allowed unconditionally.
contract MockAuthorizer is IAuthorizer {
    function canPerform(
        bytes32,
        address,
        address
    ) external pure override returns (bool) {
        return true;
    }

    function getActionId(bytes4) external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}
