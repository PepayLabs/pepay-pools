// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IDnmPool {
    enum OracleMode {
        Spot,
        Strict
    }

    struct QuoteResult {
        uint256 amountOut;
        uint256 midUsed;
        uint256 feeBpsUsed;
        uint256 partialFillAmountIn;
        bool usedFallback;
        bytes32 reason;
    }

    function quoteSwapExactIn(uint256 amountIn, bool isBaseIn, OracleMode mode, bytes calldata oracleData)
        external
        returns (QuoteResult memory);

    function swapExactIn(
        uint256 amountIn,
        uint256 minAmountOut,
        bool isBaseIn,
        OracleMode mode,
        bytes calldata oracleData,
        uint256 deadline
    ) external returns (uint256 amountOut);

    function getTopOfBookQuote(uint256 s0Notional)
        external
        view
        returns (uint256 bidPx, uint256 askPx, uint256 ttlMs, bytes32 quoteId);

    function tokens()
        external
        view
        returns (
            address baseToken,
            address quoteToken,
            uint8 baseDecimals,
            uint8 quoteDecimals,
            uint256 baseScale,
            uint256 quoteScale
        );

    function pause() external;

    function unpause() external;
}
