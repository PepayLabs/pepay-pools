// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {FixedPointMath} from "../../contracts/lib/FixedPointMath.sol";

contract FixedPointMathTest is Test {
    function callMulDivDown(uint256 x, uint256 y, uint256 denominator) external pure returns (uint256) {
        return FixedPointMath.mulDivDown(x, y, denominator);
    }

    function callMulDivUp(uint256 x, uint256 y, uint256 denominator) external pure returns (uint256) {
        return FixedPointMath.mulDivUp(x, y, denominator);
    }

    function testMulDivDownMatchesExpectations() public {
        uint256 result = FixedPointMath.mulDivDown(25, 4, 3);
        assertEq(result, 33, "mulDivDown floors");
    }

    function testMulDivUpRoundsUp() public {
        uint256 result = FixedPointMath.mulDivUp(25, 4, 3);
        assertEq(result, 34, "mulDivUp rounds");
    }

    function testMulDivZeroDenominatorReverts() public {
        vm.expectRevert(FixedPointMath.MathZeroDivision.selector);
        this.callMulDivDown(1, 2, 0);
    }

    function testMulDivOverflowReverts() public {
        vm.expectRevert(FixedPointMath.MathOverflow.selector);
        this.callMulDivDown(type(uint256).max, type(uint256).max, 1);
    }

    function testToBpsHandlesZeroDenominator() public {
        assertEq(FixedPointMath.toBps(100, 0), 0, "bps zero denominator");
    }

    function testToBps() public {
        assertEq(FixedPointMath.toBps(50, 200), 2500, "bps compute");
    }

    function testToWadScalingUp() public {
        assertEq(FixedPointMath.toWad(1_000_000, 6), 1e18, "wad scale");
    }

    function testToWadScalingDown() public {
        assertEq(FixedPointMath.toWad(1e20, 20), 1e18, "wad scale down");
    }

    function testFromWadScalingDown() public {
        assertEq(FixedPointMath.fromWad(1e18, 6), 1_000_000, "fromWad");
    }

    function testAbsDiff() public {
        assertEq(FixedPointMath.absDiff(5, 8), 3, "abs diff");
        assertEq(FixedPointMath.absDiff(8, 5), 3, "abs diff symmetric");
    }

    function testMinMax() public {
        assertEq(FixedPointMath.min(10, 2), 2, "min");
        assertEq(FixedPointMath.max(10, 2), 10, "max");
    }

    function testMulDivUpFuzz(uint256 x, uint256 y, uint256 denominator) public {
        denominator = bound(denominator, 1, type(uint128).max);
        x = bound(x, 1, type(uint128).max);
        y = bound(y, 1, type(uint128).max);
        uint256 down = FixedPointMath.mulDivDown(x, y, denominator);
        uint256 up = FixedPointMath.mulDivUp(x, y, denominator);
        assertTrue(up == down || up == down + 1, "up increments at most 1");
    }
}
