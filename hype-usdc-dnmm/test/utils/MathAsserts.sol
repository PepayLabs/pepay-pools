// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

/// @notice Common numerical assertions tuned for the DNMM fixed-point conventions.
abstract contract MathAsserts is Test {
    uint256 internal constant BPS = 10_000;

    function assertApproxRelBps(uint256 actual, uint256 expected, uint256 toleranceBps, string memory err)
        internal
        pure
    {
        if (expected == 0) {
            assertEq(actual, 0, err);
            return;
        }
        uint256 diff = actual > expected ? actual - expected : expected - actual;
        uint256 relBps = diff * BPS / expected;
        super.assertLe(relBps, toleranceBps, err);
    }

    function assertApproxWad(uint256 actual, uint256 expected, uint256 toleranceBps, string memory err) internal pure {
        assertApproxRelBps(actual, expected, toleranceBps, err);
    }

    function assertLte(uint256 actual, uint256 expected, string memory err) internal pure {
        super.assertLe(actual, expected, err);
    }

    function assertGte(uint256 actual, uint256 expected, string memory err) internal pure {
        super.assertGe(actual, expected, err);
    }
}
