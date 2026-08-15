// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.7.6;

import "../src/contract/interface/deposit/RocketDepositPoolInterface.sol";
import "../src/contract/contract/token/RocketTokenRETH.sol";
import "./MockStorage.sol";

/// @notice RocketDepositPool mock. Models a pool where all ETH is "excess"
/// (unassigned, withdrawable). ETH enters via deposit()/recycle* and leaves via
/// withdrawExcessBalance(). assignToValidator() moves ETH out to a validator
/// (staking), which keeps backing (ETH total) conserved while shrinking the
/// liquid collateral visible to RocketTokenRETH.getTotalCollateral().
contract MockDepositPool is RocketDepositPoolInterface {
    MockStorage internal rocketStorage;
    address internal validator;

    constructor(MockStorage _storage, address _validator) {
        rocketStorage = _storage;
        validator = _validator;
    }

    receive() external payable {}

    function getBalance() external view override returns (uint256) {
        return address(this).balance;
    }

    function getExcessBalance() external view override returns (uint256) {
        return address(this).balance;
    }

    function deposit() external payable override {
        rocketStorage.setUserDepositBlock(msg.sender, block.number);
    }

    /// Mint rETH against freshly deposited ETH with this pool as msg.sender,
    /// mirroring the real RocketTokenRETH.mint() gating (only the deposit pool
    /// may mint).
    function mintReth(RocketTokenRETH reth, uint256 ethAmount, address to) external {
        reth.mint(ethAmount, to);
    }

    /// Send pool-held excess ETH to rETH with this pool as msg.sender, mirroring
    /// the real RocketTokenRETH.depositExcess() gating (only the deposit pool).
    function depositExcessReth(RocketTokenRETH reth, uint256 amount) external {
        reth.depositExcess{value: amount}();
    }

    function recycleDissolvedDeposit() external payable override {}

    function recycleExcessCollateral() external payable override {}

    function recycleLiquidatedStake() external payable override {}

    function assignDeposits() external override {}

    function assignToValidator(uint256 _amount) external {
        require(_amount <= address(this).balance, "Insufficient pool balance");
        (bool ok, ) = validator.call{value: _amount}("");
        require(ok, "Validator transfer failed");
    }

    function withdrawExcessBalance(uint256 _amount) external override {
        require(_amount <= address(this).balance, "Insufficient pool balance");
        (bool ok, ) = msg.sender.call{value: _amount}("");
        require(ok, "Withdrawal transfer failed");
    }

    function getUserLastDepositBlock(address _address) external view override returns (uint256) {
        return rocketStorage.getUserDepositBlock(_address);
    }
}
