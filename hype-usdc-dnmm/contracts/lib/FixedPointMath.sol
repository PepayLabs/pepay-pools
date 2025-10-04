// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Fixed-point math helpers supporting basis points (1e4) and wad (1e18) scaling.
library FixedPointMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    error MathOverflow();
    error MathZeroDivision();

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function mulDivDown(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        result = _mulDiv(x, y, denominator, false);
    }

    function mulDivUp(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        result = _mulDiv(x, y, denominator, true);
    }

    function toBps(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) return 0;
        return mulDivDown(numerator, BPS, denominator);
    }

    function toWad(uint256 value, uint8 decimals) internal pure returns (uint256) {
        if (decimals >= 18) {
            return value / 10 ** (decimals - 18);
        }
        return value * 10 ** (18 - decimals);
    }

    function fromWad(uint256 value, uint8 decimals) internal pure returns (uint256) {
        if (decimals >= 18) {
            return value * 10 ** (decimals - 18);
        }
        return value / 10 ** (18 - decimals);
    }

    function sqrt(uint256 x) internal pure returns (uint256 result) {
        if (x == 0) {
            return 0;
        }

        uint256 z = (x + 1) >> 1;
        result = x;
        while (z < result) {
            result = z;
            z = (x / z + z) >> 1;
        }
    }

    function _mulDiv(uint256 x, uint256 y, uint256 denominator, bool roundUp) private pure returns (uint256 result) {
        if (denominator == 0) revert MathZeroDivision();

        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly ("memory-safe") {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                uint256 q = prod0 / denominator;
                if (roundUp && prod0 % denominator != 0) {
                    q += 1;
                }
                return q;
            }

            if (denominator <= prod1) revert MathOverflow();

            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(x, y, denominator)
            }
            bool shouldRound = roundUp && remainder != 0;

            assembly ("memory-safe") {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = denominator & (~denominator + 1);
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inverse = _modInverse(denominator);
            // slither-disable-next-line divide-before-multiply
            result = prod0 * inverse;

            if (shouldRound) {
                result += 1;
            }
        }
    }

    function _modInverse(uint256 a) private pure returns (uint256 inverse) {
        unchecked {
            // slither-disable-next-line incorrect-exp
            inverse = (3 * a) ^ 2;
            inverse *= 2 - a * inverse;
            inverse *= 2 - a * inverse;
            inverse *= 2 - a * inverse;
            inverse *= 2 - a * inverse;
            inverse *= 2 - a * inverse;
            inverse *= 2 - a * inverse;
        }
    }
}
