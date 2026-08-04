// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "../src/vault/interfaces/IFlashLoanRecipient.sol";
import "../src/lib/openzeppelin/IERC20.sol";

/// @notice Flash loan recipient for the Balancer V2 invariant harness.
/// mode 0 = fully repay (amount + fee), 1 = never repay (vault must revert),
/// 2 = under-repay (only half the amount; vault must revert).
contract FlashLoanRecipient is IFlashLoanRecipient {
    uint256 public immutable mode;

    constructor(uint256 mode_) {
        mode = mode_;
    }

    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory
    ) external override {
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (mode == 0) {
                tokens[i].transfer(msg.sender, amounts[i] + feeAmounts[i]);
            } else if (mode == 2) {
                tokens[i].transfer(msg.sender, amounts[i] / 2);
            }
            // mode 1: keep everything -> the Vault's post-loan balance check must revert.
        }
    }
}
