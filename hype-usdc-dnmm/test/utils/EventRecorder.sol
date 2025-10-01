// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";

/// @notice Utilities to decode DNMM events and derive reusable metrics inside tests.
library EventRecorder {
    bytes32 internal constant SWAP_EXECUTED_SIG =
        keccak256("SwapExecuted(address,bool,uint256,uint256,uint256,uint256,bool,bytes32)");
    bytes32 internal constant QUOTE_SERVED_SIG =
        keccak256("QuoteServed(uint256,uint256,uint256,uint256,uint256,uint256)");
    bytes32 internal constant TARGET_XSTAR_SIG = keccak256("TargetBaseXstarUpdated(uint128,uint128,uint256,uint64)");
    bytes32 internal constant CONF_DEBUG_SIG =
        keccak256("ConfidenceDebug(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");
    bytes32 internal constant ORACLE_SNAPSHOT_SIG =
        keccak256("OracleSnapshot(bytes32,uint256,uint256,uint256,uint256,uint256,bool,bool,bool)");
    bytes32 internal constant AOMQ_ACTIVATED_SIG =
        keccak256("AomqActivated(bytes32,bool,uint256,uint256,uint16)");

    bytes32 internal constant REASON_NONE = bytes32(0);
    bytes32 internal constant REASON_FLOOR = bytes32("FLOOR");
    bytes32 internal constant REASON_EMA = bytes32("EMA");
    bytes32 internal constant REASON_PYTH = bytes32("PYTH");
    bytes32 internal constant REASON_SPREAD = bytes32("SPREAD");

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

    struct VWAPMetrics {
        uint256 executedVwap; // 1e18 scaled
        uint256 midVwap; // 1e18 scaled
        int256 diffBps; // signed basis point delta between executed and mid VWAPs
        uint256 totalBaseVolume; // 1e18 scaled
        uint256 totalQuoteVolume; // 1e18 scaled
    }

    struct FeeComponentSeries {
        uint256[] baseComponentBps;
        uint256[] confidenceComponentBps;
        uint256[] inventoryComponentBps;
        uint256[] totalFeeBps;
    }

    struct RejectionCounts {
        uint256 total;
        uint256 none;
        uint256 floor;
        uint256 ema;
        uint256 pyth;
        uint256 spread;
        uint256 partials;
    }

    struct ConfidenceDebugEvent {
        uint256 confSpreadBps;
        uint256 confSigmaBps;
        uint256 confPythBps;
        uint256 confBlendedBps;
        uint256 sigmaBps;
        uint256 feeBaseBps;
        uint256 feeVolBps;
        uint256 feeInvBps;
        uint256 feeTotalBps;
    }

    struct OracleSnapshotEvent {
        bytes32 label;
        uint256 mid;
        uint256 ageSec;
        uint256 spreadBps;
        uint256 pythMid;
        uint256 deltaBps;
        bool hcSuccess;
        bool bookSuccess;
        bool pythSuccess;
    }

    struct AomqEvent {
        bytes32 trigger;
        bool isBaseIn;
        uint256 amountIn;
        uint256 quoteNotional;
        uint16 spreadBps;
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
            (
                bool isBaseIn,
                uint256 amountIn,
                uint256 amountOut,
                uint256 mid,
                uint256 feeBps,
                bool isPartial,
                bytes32 reason
            ) = abi.decode(logEntry.data, (bool, uint256, uint256, uint256, uint256, bool, bytes32));
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

    function decodeOracleSnapshots(Vm.Log[] memory logs) internal pure returns (OracleSnapshotEvent[] memory events) {
        uint256 count;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == ORACLE_SNAPSHOT_SIG) {
                count += 1;
            }
        }

        events = new OracleSnapshotEvent[](count);
        uint256 ptr;
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory logEntry = logs[i];
            if (logEntry.topics.length == 0 || logEntry.topics[0] != ORACLE_SNAPSHOT_SIG) {
                continue;
            }

            require(logEntry.data.length == 32 * 9, "snapshot data");

            (
                bytes32 label,
                uint256 mid,
                uint256 ageSec,
                uint256 spreadBps,
                uint256 pythMid,
                uint256 deltaBps,
                bool hcSuccess,
                bool bookSuccess,
                bool pythSuccess
            ) = abi.decode(logEntry.data, (bytes32, uint256, uint256, uint256, uint256, uint256, bool, bool, bool));

            events[ptr++] = OracleSnapshotEvent({
                label: label,
                mid: mid,
                ageSec: ageSec,
                spreadBps: spreadBps,
                pythMid: pythMid,
                deltaBps: deltaBps,
                hcSuccess: hcSuccess,
                bookSuccess: bookSuccess,
                pythSuccess: pythSuccess
            });
        }
    }

    function decodeQuoteServedEvents(Vm.Log[] memory entries)
        internal
        pure
        returns (QuoteServedEvent[] memory quotes)
    {
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
            (uint256 bidPx, uint256 askPx, uint256 s0Notional, uint256 ttlMs, uint256 mid, uint256 feeBps) =
                abi.decode(logEntry.data, (uint256, uint256, uint256, uint256, uint256, uint256));
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

    function decodeConfidenceDebug(Vm.Log[] memory entries)
        internal
        pure
        returns (ConfidenceDebugEvent[] memory events)
    {
        uint256 count;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == CONF_DEBUG_SIG) {
                ++count;
            }
        }
        events = new ConfidenceDebugEvent[](count);
        uint256 ptr;
        for (uint256 i = 0; i < entries.length; ++i) {
            Vm.Log memory logEntry = entries[i];
            if (logEntry.topics.length == 0 || logEntry.topics[0] != CONF_DEBUG_SIG) continue;
            (
                uint256 confSpreadBps,
                uint256 confSigmaBps,
                uint256 confPythBps,
                uint256 confBlendedBps,
                uint256 sigmaBps,
                uint256 feeBaseBps,
                uint256 feeVolBps,
                uint256 feeInvBps,
                uint256 feeTotalBps
            ) = abi.decode(
                logEntry.data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256)
            );
            events[ptr++] = ConfidenceDebugEvent({
                confSpreadBps: confSpreadBps,
                confSigmaBps: confSigmaBps,
                confPythBps: confPythBps,
                confBlendedBps: confBlendedBps,
                sigmaBps: sigmaBps,
                feeBaseBps: feeBaseBps,
                feeVolBps: feeVolBps,
                feeInvBps: feeInvBps,
                feeTotalBps: feeTotalBps
            });
        }
    }

    function computeVWAPMetrics(SwapEvent[] memory swaps, uint8 baseDecimals, uint8 quoteDecimals)
        internal
        pure
        returns (VWAPMetrics memory metrics)
    {
        if (swaps.length == 0) return metrics;

        uint256 baseScale = 10 ** baseDecimals;
        uint256 quoteScale = 10 ** quoteDecimals;

        for (uint256 i = 0; i < swaps.length; ++i) {
            SwapEvent memory evt = swaps[i];
            (uint256 baseVol, uint256 quoteVol, uint256 price) = _tradeVolumesAndPrice(evt, baseScale, quoteScale);
            if (baseVol == 0) continue;

            metrics.totalBaseVolume += baseVol;
            metrics.totalQuoteVolume += quoteVol;
            metrics.executedVwap += price * baseVol;
            metrics.midVwap += evt.mid * baseVol;
        }

        if (metrics.totalBaseVolume == 0) {
            metrics.executedVwap = 0;
            metrics.midVwap = 0;
            metrics.diffBps = 0;
        } else {
            metrics.executedVwap = metrics.executedVwap / metrics.totalBaseVolume;
            metrics.midVwap = metrics.midVwap / metrics.totalBaseVolume;
            metrics.diffBps = _diffBps(metrics.executedVwap, metrics.midVwap);
        }
    }

    function computeFeeComponents(
        FeePolicy.FeeConfig memory cfg,
        uint256[] memory confBpsSeries,
        uint256[] memory inventoryDeviationBpsSeries
    ) internal pure returns (FeeComponentSeries memory series) {
        require(confBpsSeries.length == inventoryDeviationBpsSeries.length, "INV_SERIES_LEN");

        uint256 len = confBpsSeries.length;
        series.baseComponentBps = new uint256[](len);
        series.confidenceComponentBps = new uint256[](len);
        series.inventoryComponentBps = new uint256[](len);
        series.totalFeeBps = new uint256[](len);

        for (uint256 i = 0; i < len; ++i) {
            uint256 confComponent = cfg.alphaConfDenominator == 0
                ? 0
                : (confBpsSeries[i] * cfg.alphaConfNumerator) / cfg.alphaConfDenominator;
            uint256 invComponent = cfg.betaInvDevDenominator == 0
                ? 0
                : (inventoryDeviationBpsSeries[i] * cfg.betaInvDevNumerator) / cfg.betaInvDevDenominator;
            uint256 total = cfg.baseBps + confComponent + invComponent;
            if (total > cfg.capBps) total = cfg.capBps;

            series.baseComponentBps[i] = cfg.baseBps;
            series.confidenceComponentBps[i] = confComponent;
            series.inventoryComponentBps[i] = invComponent;
            series.totalFeeBps[i] = total;
        }
    }

    function countRejections(SwapEvent[] memory swaps) internal pure returns (RejectionCounts memory counts) {
        counts.total = swaps.length;
        for (uint256 i = 0; i < swaps.length; ++i) {
            SwapEvent memory evt = swaps[i];
            if (evt.isPartial) counts.partials += 1;

            if (evt.reason == REASON_NONE) {
                counts.none += 1;
            } else if (evt.reason == REASON_FLOOR) {
                counts.floor += 1;
            } else if (evt.reason == REASON_EMA) {
                counts.ema += 1;
            } else if (evt.reason == REASON_PYTH) {
                counts.pyth += 1;
            } else if (evt.reason == REASON_SPREAD) {
                counts.spread += 1;
            }
        }
    }

    function decodeAomqEvents(Vm.Log[] memory entries) internal pure returns (AomqEvent[] memory events) {
        uint256 count;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == AOMQ_ACTIVATED_SIG) {
                ++count;
            }
        }

        events = new AomqEvent[](count);
        uint256 ptr;
        for (uint256 i = 0; i < entries.length; ++i) {
            Vm.Log memory logEntry = entries[i];
            if (logEntry.topics.length == 0 || logEntry.topics[0] != AOMQ_ACTIVATED_SIG) continue;

            (bytes32 trigger, bool isBaseIn, uint256 amountIn, uint256 quoteNotional, uint16 spreadBps) =
                abi.decode(logEntry.data, (bytes32, bool, uint256, uint256, uint16));

            events[ptr++] = AomqEvent({
                trigger: trigger,
                isBaseIn: isBaseIn,
                amountIn: amountIn,
                quoteNotional: quoteNotional,
                spreadBps: spreadBps
            });
        }
    }

    function writeCSV(Vm vm, string memory path, string memory header, string[] memory rows) internal {
        string memory body = header;
        for (uint256 i = 0; i < rows.length; ++i) {
            body = string.concat(body, "\n", rows[i]);
        }
        _writeFile(vm, path, body);
    }

    function writeJSON(Vm vm, string memory path, string memory jsonPayload) internal {
        _writeFile(vm, path, jsonPayload);
    }

    function uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function intToString(int256 value) internal pure returns (string memory) {
        if (value >= 0) {
            return uintToString(uint256(value));
        }
        return string.concat("-", uintToString(uint256(-value)));
    }

    function targetXstarSig() internal pure returns (bytes32) {
        return TARGET_XSTAR_SIG;
    }

    function computePearsonCorrelation(uint256[] memory x, uint256[] memory y) internal pure returns (int256) {
        require(x.length == y.length && x.length > 1, "CORR_INPUT");

        uint256 len = x.length;
        int256 sumX;
        int256 sumY;
        for (uint256 i = 0; i < len; ++i) {
            sumX += int256(uint256(x[i]));
            sumY += int256(uint256(y[i]));
        }

        int256 meanX = sumX / int256(uint256(len));
        int256 meanY = sumY / int256(uint256(len));

        int256 numerator;
        uint256 sumSqX;
        uint256 sumSqY;

        for (uint256 i = 0; i < len; ++i) {
            int256 dx = int256(uint256(x[i])) - meanX;
            int256 dy = int256(uint256(y[i])) - meanY;
            numerator += dx * dy;
            sumSqX += uint256(dx * dx);
            sumSqY += uint256(dy * dy);
        }

        if (sumSqX == 0 || sumSqY == 0) {
            return 0;
        }

        uint256 denom = _sqrt(sumSqX * sumSqY);
        if (denom == 0) {
            return 0;
        }

        return (numerator * int256(10_000)) / int256(denom);
    }

    function _writeFile(Vm vm, string memory path, string memory data) private {
        string memory quotedPath = string.concat("'", path, "'");
        string memory command =
            string.concat("mkdir -p $(dirname ", quotedPath, ") && cat <<'EOF' > ", quotedPath, "\n", data, "\nEOF\n");
        string[] memory inputs = new string[](3);
        inputs[0] = "bash";
        inputs[1] = "-lc";
        inputs[2] = command;
        vm.ffi(inputs);
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _tradeVolumesAndPrice(SwapEvent memory evt, uint256 baseScale, uint256 quoteScale)
        private
        pure
        returns (uint256 baseVolumeE18, uint256 quoteVolumeE18, uint256 price)
    {
        (uint256 baseRaw, uint256 quoteRaw) =
            evt.isBaseIn ? (evt.amountIn, evt.amountOut) : (evt.amountOut, evt.amountIn);

        if (baseRaw == 0 || quoteRaw == 0) {
            return (0, 0, 0);
        }

        baseVolumeE18 = (baseRaw * 1e18) / baseScale;
        quoteVolumeE18 = (quoteRaw * 1e18) / quoteScale;
        if (baseVolumeE18 == 0) {
            return (0, 0, 0);
        }
        price = (quoteVolumeE18 * 1e18) / baseVolumeE18;
    }

    function _diffBps(uint256 executed, uint256 mid) private pure returns (int256) {
        if (executed == 0 || mid == 0) {
            return 0;
        }
        if (executed == mid) {
            return 0;
        }
        if (executed > mid) {
            return int256(((executed - mid) * 10_000) / mid);
        }
        return -int256(((mid - executed) * 10_000) / mid);
    }
}
