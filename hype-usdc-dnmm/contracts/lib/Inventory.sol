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
        uint256 availableQuote = availableInventory(quoteReserves, floorBps);

        uint256 netQuoteWadFull = _netQuoteWadFromBaseIn(amountIn, mid, feeBps, tokens);
        amountOut = FixedPointMath.mulDivDown(netQuoteWadFull, tokens.quoteScale, ONE);

        if (amountOut <= availableQuote) {
            return (amountOut, amountIn, false);
        }

        if (availableQuote == 0) revert Errors.FloorBreach();

        uint256 netQuoteWadTarget = FixedPointMath.mulDivDown(availableQuote, ONE, tokens.quoteScale);
        uint256 appliedCandidate = _baseInForNetQuoteWad(netQuoteWadTarget, mid, feeBps, tokens);
        assert(appliedCandidate <= amountIn);
        appliedAmountIn = appliedCandidate;

        uint256 netQuoteWadApplied = _netQuoteWadFromBaseIn(appliedAmountIn, mid, feeBps, tokens);
        amountOut = FixedPointMath.mulDivDown(netQuoteWadApplied, tokens.quoteScale, ONE);
        if (amountOut > availableQuote) {
            amountOut = availableQuote;
        }

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
        uint256 baseFloor = floorAmount(baseReserves, floorBps);
        uint256 availableBase = baseReserves > baseFloor ? baseReserves - baseFloor : 0;

        uint256 netBaseWadFull = _netBaseWadFromQuoteIn(amountIn, mid, feeBps, tokens);
        amountOut = FixedPointMath.mulDivDown(netBaseWadFull, tokens.baseScale, ONE);

        if (amountOut <= availableBase) {
            return (amountOut, amountIn, false);
        }

        if (availableBase == 0) revert Errors.FloorBreach();

        uint256 netBaseWadTarget = FixedPointMath.mulDivDown(availableBase, ONE, tokens.baseScale);
        uint256 appliedCandidate = _quoteInForNetBaseWad(netBaseWadTarget, mid, feeBps, tokens);
        assert(appliedCandidate <= amountIn);
        appliedAmountIn = appliedCandidate;

        uint256 netBaseWadApplied = _netBaseWadFromQuoteIn(appliedAmountIn, mid, feeBps, tokens);
        uint256 desiredBaseOut = FixedPointMath.mulDivDown(netBaseWadApplied, tokens.baseScale, ONE);
        amountOut = _clampToFloor(desiredBaseOut, baseReserves, baseFloor);

        return (amountOut, appliedAmountIn, true);
    }

    function _netQuoteWadFromBaseIn(uint256 amountIn, uint256 mid, uint256 feeBps, Tokens memory tokens)
        private
        pure
        returns (uint256 netQuoteWad)
    {
        uint256 amountInWad = FixedPointMath.mulDivDown(amountIn, ONE, tokens.baseScale);
        if (amountInWad == 0) return 0;

        uint256 grossQuoteWad = FixedPointMath.mulDivDown(amountInWad, mid, ONE);
        if (grossQuoteWad == 0) return 0;

        uint256 feeWad = feeBps == 0 ? 0 : FixedPointMath.mulDivDown(grossQuoteWad, feeBps, BPS);
        return grossQuoteWad - feeWad;
    }

    function _baseInForNetQuoteWad(uint256 netQuoteWad, uint256 mid, uint256 feeBps, Tokens memory tokens)
        private
        pure
        returns (uint256)
    {
        if (netQuoteWad == 0) return 0;
        uint256 grossQuoteWad = feeBps == 0 ? netQuoteWad : FixedPointMath.mulDivUp(netQuoteWad, BPS, BPS - feeBps);
        uint256 amountInWad = FixedPointMath.mulDivUp(grossQuoteWad, ONE, mid);
        return FixedPointMath.mulDivUp(amountInWad, tokens.baseScale, ONE);
    }

    function _netBaseWadFromQuoteIn(uint256 amountIn, uint256 mid, uint256 feeBps, Tokens memory tokens)
        private
        pure
        returns (uint256 netBaseWad)
    {
        uint256 amountInWad = FixedPointMath.mulDivDown(amountIn, ONE, tokens.quoteScale);
        if (amountInWad == 0) return 0;

        uint256 grossBaseWad = FixedPointMath.mulDivDown(amountInWad, ONE, mid);
        if (grossBaseWad == 0) return 0;

        uint256 feeWad = feeBps == 0 ? 0 : FixedPointMath.mulDivDown(grossBaseWad, feeBps, BPS);
        return grossBaseWad - feeWad;
    }

    function _quoteInForNetBaseWad(uint256 netBaseWad, uint256 mid, uint256 feeBps, Tokens memory tokens)
        private
        pure
        returns (uint256)
    {
        if (netBaseWad == 0) return 0;
        uint256 grossBaseWad = feeBps == 0 ? netBaseWad : FixedPointMath.mulDivUp(netBaseWad, BPS, BPS - feeBps);
        uint256 amountInWad = FixedPointMath.mulDivUp(grossBaseWad, mid, ONE);
        return FixedPointMath.mulDivUp(amountInWad, tokens.quoteScale, ONE);
    }

    function _clampToFloor(uint256 desiredBaseOut, uint256 baseReserve, uint256 baseFloor)
        internal
        pure
        returns (uint256 clampedBaseOut)
    {
        if (baseReserve <= baseFloor) return 0;
        uint256 maxOut = baseReserve - baseFloor;
        return desiredBaseOut > maxOut ? maxOut : desiredBaseOut;
    }
}
