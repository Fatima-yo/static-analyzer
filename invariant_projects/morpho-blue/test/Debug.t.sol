// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./MorphoHandler.sol";

/// @notice Temporary debug harness for the failing shrunk sequence.
contract DebugMorpho {
    MorphoHandler internal h;

    uint256 public stepDelta;
    uint256 public lastStep;

    constructor() {
        h = new MorphoHandler();
    }

    function _usdcDelta() internal view returns (uint256) {
        (uint256 mu, , uint256 saA, uint256 baA, , , , uint256 collB, , , , , , , , ) = h.conservationBreakdown();
        uint256 rhs = saA - baA + collB;
        return mu > rhs ? mu - rhs : rhs - mu;
    }

    function _step() internal {
        ++lastStep;
        stepDelta = _usdcDelta();
        int256 usdcR = h.lastUsdcResidual();
        int256 wethR = h.lastWethResidual();
        require(
            usdcR >= 0 && usdcR <= 1 && wethR >= 0 && wethR <= 1,
            string(
                abi.encodePacked(
                    "step ", _str(lastStep),
                    " absDelta ", _str(stepDelta),
                    " usdcResidual ", _str(uint256(usdcR)),
                    " wethResidual ", _str(uint256(wethR))
                )
            )
        );
    }

    function _str(uint256 x) internal pure returns (string memory) {
        if (x == 0) return "0";
        bytes memory buf = new bytes(78);
        uint256 i = buf.length;
        while (x != 0) {
            i--;
            buf[i] = bytes1(uint8(48 + x % 10));
            x /= 10;
        }
        bytes memory out = new bytes(buf.length - i);
        for (uint256 j = 0; j < out.length; ++j) {
            out[j] = buf[i + j];
        }
        return string(out);
    }

    function test_shrunk_sequence() public {
        _step();
        h.supplyCollateral(3, 6247591787);
        _step();
        h.supply(1292113535456779174786689612851575629258874457652064375887647018899, 20985447850211917623790426170897053955490814614297185198);
        _step();
        h.borrow(3, 12189569266981262250);
        _step();
        h.repay(1276486048483, 47199968768136863574992707110227448135944467476089660055341488964286);
        _step();
        h.repay(3, 1307);
        _step();
    }

    function test_second_sequence() public {
        h.supply(2328486, 184721085104375314623937);
        _step();
        h.supplyCollateral(50000000000000000, 1613248986);
        _step();
        h.borrow(7488, 1000000000000);
        _step();
        h.repay(300000000000000000, 1757);
        _step();
        h.repay(31536000, 2);
        _step();
        h.repay(1000000000000000000, 6967);
        _step();
    }
}
