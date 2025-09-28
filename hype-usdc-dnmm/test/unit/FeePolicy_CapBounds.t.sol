// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";

contract FeePolicyCapBoundsTest is Test {
    function _cfg(uint16 baseBps, uint16 capBps) internal pure returns (FeePolicy.FeeConfig memory cfg) {
        cfg = FeePolicy.FeeConfig({
            baseBps: baseBps,
            alphaConfNumerator: 60,
            alphaConfDenominator: 100,
            betaInvDevNumerator: 12,
            betaInvDevDenominator: 100,
            capBps: capBps,
            decayPctPerBlock: 10
        });
    }

    function test_packRevertsWhenCapAtOrAbove100Percent() external {
        FeePolicy.FeeConfig memory cfg = _cfg(50, 10_000);
        vm.expectRevert(abi.encodeWithSelector(FeePolicy.FeeCapTooHigh.selector, uint16(10_000)));
        FeePolicy.pack(cfg);
    }

    function test_packRevertsWhenBaseExceedsCap() external {
        FeePolicy.FeeConfig memory cfg = _cfg(200, 150);
        vm.expectRevert(abi.encodeWithSelector(FeePolicy.FeeBaseAboveCap.selector, uint16(200), uint16(150)));
        FeePolicy.pack(cfg);
    }

    function test_packAllowsValidBounds() external {
        FeePolicy.FeeConfig memory cfg = _cfg(150, 9_999);
        uint256 packed = FeePolicy.pack(cfg);
        (,,,,, uint16 capBps,) = FeePolicy.decode(packed);
        assertEq(capBps, cfg.capBps, "cap bps");
    }
}
