// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library MathUtils {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function mulDivDown(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        require(denominator != 0, "DIV_ZERO");
        assembly {
            let prod := mul(a, b)
            if iszero(eq(a, 0x0)) {
                if gt(div(prod, a), b) { revert(0, 0) }
            }
            result := div(prod, denominator)
        }
    }

    function mulDivUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        require(denominator != 0, "DIV_ZERO");
        uint256 prod = a * b;
        require(a == 0 || prod / a == b, "MUL_OVERFLOW");
        if (prod % denominator == 0) {
            result = prod / denominator;
        } else {
            result = prod / denominator + 1;
        }
    }

    function toBps(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) return 0;
        return mulDivDown(numerator, BPS, denominator);
    }
}
