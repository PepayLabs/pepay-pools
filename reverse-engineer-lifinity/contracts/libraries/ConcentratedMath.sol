// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ConcentratedMath
 * @notice Math library for concentrated liquidity calculations
 */
library ConcentratedMath {
    uint256 private constant PRECISION = 1e18;

    /**
     * @notice Calculate square root using Babylonian method
     */
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;

        uint256 z = (x + 1) / 2;
        uint256 y = x;

        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }

        return y;
    }

    /**
     * @notice Calculate power with fractional exponent
     * @dev Simplified implementation - production would need more precision
     */
    function pow(uint256 base, uint256 exponent) internal pure returns (uint256) {
        if (exponent == 0) return PRECISION;
        if (exponent == PRECISION) return base;

        // For fractional exponents, use approximation
        // This is simplified - production needs proper implementation
        uint256 whole = exponent / PRECISION;
        uint256 fraction = exponent % PRECISION;

        uint256 result = PRECISION;

        // Handle whole part
        for (uint256 i = 0; i < whole; i++) {
            result = (result * base) / PRECISION;
        }

        // Handle fractional part (linear approximation)
        if (fraction > 0) {
            uint256 fractionalPart = ((base - PRECISION) * fraction) / PRECISION;
            result = (result * (PRECISION + fractionalPart)) / PRECISION;
        }

        return result;
    }

    /**
     * @notice Safe multiplication
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a * b;
        require(c / a == b, "Multiplication overflow");
        return c;
    }

    /**
     * @notice Safe division
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "Division by zero");
        return a / b;
    }
}