// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMath} from "./FixedPointMath.sol";
import {Errors} from "./Errors.sol";

library Inventory {
    uint256 private constant ONE = 1e18;
    uint256 private constant BPS = 10_000;

    struct Tokens {
        uint256 baseScale;
        uint256 quoteScale;
    }

    function floorAmount(uint256 reserves, uint16 floorBps) internal pure returns (uint256) {
        return FixedPointMath.mulDivDown(reserves, floorBps, BPS);
    }

    function availableInventory(uint256 reserves, uint16 floorBps) internal pure returns (uint256) {
        uint256 floor = floorAmount(reserves, floorBps);
        return reserves > floor ? reserves - floor : 0;
    }

    function deviationBps(
        uint256 baseReserves,
        uint256 quoteReserves,
        uint128 targetBaseXstar,
        uint256 mid,
        Tokens memory tokens
    ) internal pure returns (uint256) {
        uint256 baseWad = FixedPointMath.mulDivDown(baseReserves, ONE, tokens.baseScale);
        uint256 quoteWad = FixedPointMath.mulDivDown(quoteReserves, ONE, tokens.quoteScale);
        uint256 targetWad = FixedPointMath.mulDivDown(uint256(targetBaseXstar), ONE, tokens.baseScale);
        uint256 baseNotionalWad = FixedPointMath.mulDivDown(baseWad, mid, ONE);
        uint256 totalNotionalWad = quoteWad + baseNotionalWad;
        if (totalNotionalWad == 0) return 0;
        uint256 deviation = FixedPointMath.absDiff(baseWad, targetWad);
        return FixedPointMath.toBps(deviation, totalNotionalWad);
    }

    function quoteBaseIn(
        uint256 amountIn,
        uint256 mid,
        uint256 feeBps,
        uint256 quoteReserves,
        uint16 floorBps,
        Tokens memory tokens
    ) internal pure returns (uint256 amountOut, uint256 appliedAmountIn, bool isPartial) {
        uint256 amountInWad = FixedPointMath.mulDivDown(amountIn, ONE, tokens.baseScale);
        uint256 grossQuoteWad = FixedPointMath.mulDivDown(amountInWad, mid, ONE);
        uint256 feeWad = FixedPointMath.mulDivDown(grossQuoteWad, feeBps, BPS);
        uint256 netQuoteWad = grossQuoteWad - feeWad;
        amountOut = FixedPointMath.mulDivDown(netQuoteWad, tokens.quoteScale, ONE);

        uint256 availableQuote = availableInventory(quoteReserves, floorBps);
        if (amountOut <= availableQuote) {
            appliedAmountIn = amountIn;
            return (amountOut, amountIn, false);
        }

        if (availableQuote == 0) revert Errors.FloorBreach();
        amountOut = availableQuote;
        isPartial = true;

        uint256 netQuoteWadPartial = FixedPointMath.mulDivDown(amountOut, ONE, tokens.quoteScale);
        uint256 grossQuoteWadPartial = FixedPointMath.mulDivUp(netQuoteWadPartial, BPS, BPS - feeBps);
        uint256 amountInWadPartial = FixedPointMath.mulDivUp(grossQuoteWadPartial, ONE, mid);
        appliedAmountIn = FixedPointMath.mulDivUp(amountInWadPartial, tokens.baseScale, ONE);
        return (amountOut, appliedAmountIn, true);
    }

    function quoteQuoteIn(
        uint256 amountIn,
        uint256 mid,
        uint256 feeBps,
        uint256 baseReserves,
        uint16 floorBps,
        Tokens memory tokens
    ) internal pure returns (uint256 amountOut, uint256 appliedAmountIn, bool isPartial) {
        uint256 amountInWad = FixedPointMath.mulDivDown(amountIn, ONE, tokens.quoteScale);
        uint256 grossBaseWad = FixedPointMath.mulDivDown(amountInWad, ONE, mid);
        uint256 feeWad = FixedPointMath.mulDivDown(grossBaseWad, feeBps, BPS);
        uint256 netBaseWad = grossBaseWad - feeWad;
        amountOut = FixedPointMath.mulDivDown(netBaseWad, tokens.baseScale, ONE);

        uint256 availableBase = availableInventory(baseReserves, floorBps);
        if (amountOut <= availableBase) {
            appliedAmountIn = amountIn;
            return (amountOut, amountIn, false);
        }

        if (availableBase == 0) revert Errors.FloorBreach();
        amountOut = availableBase;
        isPartial = true;

        uint256 netBaseWadPartial = FixedPointMath.mulDivDown(amountOut, ONE, tokens.baseScale);
        uint256 grossBaseWadPartial = FixedPointMath.mulDivUp(netBaseWadPartial, BPS, BPS - feeBps);
        uint256 amountInWadPartial = FixedPointMath.mulDivUp(grossBaseWadPartial, mid, ONE);
        appliedAmountIn = FixedPointMath.mulDivUp(amountInWadPartial, tokens.quoteScale, ONE);
        return (amountOut, appliedAmountIn, true);
    }
}
