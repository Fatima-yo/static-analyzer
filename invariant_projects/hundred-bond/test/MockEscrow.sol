// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotingEscrow, LockedBalance } from "../src/HundredBond.sol";

/// @notice veCRV-style voting escrow mock matching the interface used by
/// HundredBond. `deposit_for` / `create_lock_for` pull `_value` HND from
/// `msg.sender` (the HundredBond contract, which has approved us) and record a
/// lock for `_addr`. `deposit_for` requires an existing lock; a first deposit
/// must go through `create_lock_for`.
contract MockEscrow is IVotingEscrow {
    IERC20 public hnd;

    mapping(address => LockedBalance) internal _locked;

    constructor(IERC20 _hnd) {
        hnd = _hnd;
    }

    function locked(address _addr) external view override returns (LockedBalance memory) {
        return _locked[_addr];
    }

    function deposit_for(address _addr, uint256 _value) external override {
        LockedBalance storage l = _locked[_addr];
        require(l.amount > 0 && l.end > 0, "no existing lock");
        if (_value > 0) {
            require(hnd.transferFrom(msg.sender, address(this), _value), "pull failed");
        }
        l.amount = int128(int256(uint256(int256(l.amount)) + _value));
    }

    function create_lock_for(address _addr, uint256 _value, uint256 _unlock_time) external override {
        LockedBalance storage l = _locked[_addr];
        require(l.amount == 0 && l.end == 0, "already locked");
        require(_unlock_time > block.timestamp, "unlock in the past");
        if (_value > 0) {
            require(hnd.transferFrom(msg.sender, address(this), _value), "pull failed");
        }
        l.amount = int128(int256(_value));
        l.end = _unlock_time;
    }
}
