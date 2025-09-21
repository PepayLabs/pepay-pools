// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Vm.sol";

/// @notice Utilities to decode DNMM events and derive simple metrics inside tests.
library EventRecorder {
    bytes32 internal constant SWAP_EXECUTED_SIG = keccak256(
        "SwapExecuted(address,bool,uint256,uint256,uint256,uint256,bool,bytes32)"
    );
    bytes32 internal constant QUOTE_SERVED_SIG = keccak256(
        "QuoteServed(uint256,uint256,uint256,uint256,uint256,uint256)"
    );
    bytes32 internal constant TARGET_XSTAR_SIG = keccak256(
        "TargetBaseXstarUpdated(uint128,uint128,uint256,uint64)"
    );

    struct SwapEvent {
        address user;
        bool isBaseIn;
        uint256 amountIn;
        uint256 amountOut;
        uint256 mid;
        uint256 feeBps;
        bool isPartial;
        bytes32 reason;
    }

    struct QuoteServedEvent {
        uint256 bidPx;
        uint256 askPx;
        uint256 s0Notional;
        uint256 ttlMs;
        uint256 mid;
        uint256 feeBps;
    }

    struct SwapStats {
        uint256 totalAmountInBase;
        uint256 totalAmountInQuote;
        uint256 totalFeeBpsTimesAmount;
        uint256 trades;
        uint256 partialFills;
    }

    function decodeSwapEvents(Vm.Log[] memory entries) internal pure returns (SwapEvent[] memory swaps) {
        uint256 count;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == SWAP_EXECUTED_SIG) {
                ++count;
            }
        }
        swaps = new SwapEvent[](count);
        uint256 ptr;
        for (uint256 i = 0; i < entries.length; ++i) {
            Vm.Log memory logEntry = entries[i];
            if (logEntry.topics.length == 0 || logEntry.topics[0] != SWAP_EXECUTED_SIG) continue;
            (bool isBaseIn, uint256 amountIn, uint256 amountOut, uint256 mid, uint256 feeBps, bool isPartial, bytes32 reason) = abi.decode(
                logEntry.data,
                (bool, uint256, uint256, uint256, uint256, bool, bytes32)
            );
            swaps[ptr++] = SwapEvent({
                user: address(uint160(uint256(logEntry.topics[1]))),
                isBaseIn: isBaseIn,
                amountIn: amountIn,
                amountOut: amountOut,
                mid: mid,
                feeBps: feeBps,
                isPartial: isPartial,
                reason: reason
            });
        }
    }

    function decodeQuoteServedEvents(Vm.Log[] memory entries) internal pure returns (QuoteServedEvent[] memory quotes) {
        uint256 count;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == QUOTE_SERVED_SIG) {
                ++count;
            }
        }
        quotes = new QuoteServedEvent[](count);
        uint256 ptr;
        for (uint256 i = 0; i < entries.length; ++i) {
            Vm.Log memory logEntry = entries[i];
            if (logEntry.topics.length == 0 || logEntry.topics[0] != QUOTE_SERVED_SIG) continue;
            (uint256 bidPx, uint256 askPx, uint256 s0Notional, uint256 ttlMs, uint256 mid, uint256 feeBps) = abi.decode(
                logEntry.data,
                (uint256, uint256, uint256, uint256, uint256, uint256)
            );
            quotes[ptr++] = QuoteServedEvent({
                bidPx: bidPx,
                askPx: askPx,
                s0Notional: s0Notional,
                ttlMs: ttlMs,
                mid: mid,
                feeBps: feeBps
            });
        }
    }

    function computeStats(SwapEvent[] memory swaps, uint8 baseDecimals, uint8 quoteDecimals)
        internal
        pure
        returns (SwapStats memory stats)
    {
        for (uint256 i = 0; i < swaps.length; ++i) {
            SwapEvent memory evt = swaps[i];
            stats.trades += 1;
            if (evt.isBaseIn) {
                stats.totalAmountInBase += evt.amountIn;
                stats.totalAmountInQuote += evt.amountOut;
            } else {
                stats.totalAmountInQuote += evt.amountIn;
                stats.totalAmountInBase += evt.amountOut;
            }
            if (evt.isPartial) stats.partialFills += 1;
            stats.totalFeeBpsTimesAmount += evt.feeBps * evt.amountIn;
        }
    }

    function targetXstarSig() internal pure returns (bytes32) {
        return TARGET_XSTAR_SIG;
    }
}
