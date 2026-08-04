// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice HND governance token for the HundredBond harness.
contract Hnd is ERC20 {
    constructor() ERC20("HND", "HND") {
        _mint(msg.sender, 1_000_000 ether);
    }
}
