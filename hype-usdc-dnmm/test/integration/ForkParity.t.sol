// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {MockOracleHC} from "../../contracts/mocks/MockOracleHC.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract ForkParityTest is BaseTest {
    bytes32 private constant REASON_NONE = bytes32(0);
    bytes32 private constant REASON_EMA = bytes32("EMA");
    bytes32 private constant REASON_PYTH = bytes32("PYTH");
    uint256 private constant EVENT_COUNT = 5;

    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);
        approveAll(carol);
    }

    function test_fork_parity_paths_and_metrics() public {
        uint32 maxAgeSec;
        uint32 stallWindowSec;
        uint16 capSpot;
        uint16 capStrict;
        uint16 divergenceCap;
        (maxAgeSec, stallWindowSec, capSpot, capStrict, divergenceCap,,,,,) = pool.oracleConfig();
        assertGt(divergenceCap, 0, "divergence cap configured");
        string[] memory labels = new string[](EVENT_COUNT);
        bytes32[] memory sources = new bytes32[](EVENT_COUNT);
        uint256[] memory expectedMids = new uint256[](EVENT_COUNT);
        uint256[] memory expectedAges = new uint256[](EVENT_COUNT);
        uint256[] memory blockNumbers = new uint256[](EVENT_COUNT);

        uint256 divergenceAttempts;
        uint256 divergenceRejections;
        uint256 staleAttempts;
        uint256 staleRejections;

        recordLogs();
        uint256 idx;

        // FP1: healthy HC path
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        uint256 hcMid = 1_010_000_000_000_000_000; // 1.01 * 1e18
        updateSpot(hcMid, 3, true);
        updateBidAsk(995e15, 1025e15, 30, true);
        updateEma(hcMid, 4, true);
        updatePyth(1_010_000_000_000_000_000, 1e18, 2, 2, 25, 25);

        labels[idx] = "hc_fresh";
        sources[idx] = REASON_NONE;
        expectedMids[idx] = hcMid;
        (, uint256 spotAge,) = oracleHC.spot();
        expectedAges[idx] = spotAge;
        blockNumbers[idx] = block.number;
        swap(alice, 5 ether, 0, true, IDnmPool.OracleMode.Spot, block.timestamp + 5);
        unchecked {
            ++idx;
        }

        // FP2: EMA fallback within stall window due to spread spike
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        uint256 emaMid = 995e15; // 0.995 * 1e18
        updateSpot(1e18, 4, true);
        updateBidAsk(980e15, 1_020e15, 220, true);
        updateEma(emaMid, 5, true);
        updatePyth(1e18, 1e18, 3, 3, 20, 20);

        labels[idx] = "ema_stall";
        sources[idx] = REASON_EMA;
        (uint256 emaMidOut, uint256 emaAge,) = oracleHC.ema();
        expectedMids[idx] = emaMidOut;
        expectedAges[idx] = emaAge;
        blockNumbers[idx] = block.number;
        swap(bob, 12 ether, 0, true, IDnmPool.OracleMode.Spot, block.timestamp + 5);
        unchecked {
            ++idx;
        }

        // FP3: Precompile revert -> EMA fallback (stall window)
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        oracleHC.setResponseMode(MockOracleHC.ReadKind.Spot, MockOracleHC.ResponseMode.RevertCall);
        oracleHC.setResponseMode(MockOracleHC.ReadKind.Book, MockOracleHC.ResponseMode.RevertCall);
        updateEma(1_005_000_000_000_000_000, 4, true);
        updatePyth(1_000_000_000_000_000_000, 1e18, 20, 20, 50, 50); // stale Pyth to force EMA

        labels[idx] = "ema_precompile_revert";
        sources[idx] = REASON_EMA;
        (uint256 emaFallbackMid, uint256 emaFallbackAge,) = oracleHC.ema();
        expectedMids[idx] = emaFallbackMid;
        expectedAges[idx] = emaFallbackAge;
        blockNumbers[idx] = block.number;
        swap(carol, 8 ether, 0, true, IDnmPool.OracleMode.Spot, block.timestamp + 5);
        oracleHC.clearResponseModes();
        unchecked {
            ++idx;
        }

        // FP4: Precompile empty -> Pyth fallback
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        oracleHC.setResponseMode(MockOracleHC.ReadKind.Spot, MockOracleHC.ResponseMode.Empty);
        oracleHC.setResponseMode(MockOracleHC.ReadKind.Book, MockOracleHC.ResponseMode.Empty);
        oracleHC.setResponseMode(MockOracleHC.ReadKind.Ema, MockOracleHC.ResponseMode.Empty);
        updateEma(0, 50, false);
        updatePyth(1_030_000_000_000_000_000, 1e18, 4, 4, 30, 28);

        labels[idx] = "pyth_precompile_empty";
        sources[idx] = REASON_PYTH;
        expectedMids[idx] = 1_030_000_000_000_000_000;
        expectedAges[idx] = _pythAge();
        blockNumbers[idx] = block.number;
        swap(alice, 6 ether, 0, true, IDnmPool.OracleMode.Spot, block.timestamp + 5);
        oracleHC.clearResponseModes();
        unchecked {
            ++idx;
        }

        // FP5: Spot stale but Pyth fresh -> strict-cap fallback
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        oracleHC.clearResponseModes();
        updateSpot(1_028_000_000_000_000_000, maxAgeSec + 5, true);
        updateBidAsk(1_024_000_000_000_000_000, 1_032_000_000_000_000_000, 40, true);
        updateEma(1_025_000_000_000_000_000, stallWindowSec + 5, true);
        updatePyth(1_029_000_000_000_000_000, 1e18, 3, 3, 60, 58);

        labels[idx] = "pyth_stale_hc";
        sources[idx] = REASON_PYTH;
        expectedMids[idx] = 1_029_000_000_000_000_000;
        expectedAges[idx] = _pythAge();
        blockNumbers[idx] = block.number;
        swap(bob, 7 ether, 0, true, IDnmPool.OracleMode.Spot, block.timestamp + 5);
        unchecked {
            ++idx;
        }

        // Stall guard: all sources stale -> reject
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        updateSpot(0, 0, false);
        updateBidAsk(0, 0, 0, false);
        updateEma(1e18, 120, false);
        updatePyth(1e18, 1e18, 120, 120, 40, 40);
        unchecked {
            ++staleAttempts;
        }
        vm.expectRevert(Errors.OracleStale.selector);
        quote(10 ether, true, IDnmPool.OracleMode.Spot);
        unchecked {
            ++staleRejections;
        }

        // Invalid orderbook garbage data should fail closed
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        oracleHC.clearResponseModes();
        updateSpot(1_005e18, 3, true);
        updateBidAsk(995e15, 1_005e15, 15, true);
        oracleHC.setResponseMode(MockOracleHC.ReadKind.Book, MockOracleHC.ResponseMode.Garbage);
        vm.expectRevert(Errors.InvalidOrderbook.selector);
        quote(5 ether, true, IDnmPool.OracleMode.Spot);
        oracleHC.clearResponseModes();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        EventRecorder.SwapEvent[] memory swaps = EventRecorder.decodeSwapEvents(logs);
        EventRecorder.ConfidenceDebugEvent[] memory debugEvents = EventRecorder.decodeConfidenceDebug(logs);
        require(swaps.length == EVENT_COUNT, "swap count");
        require(debugEvents.length == EVENT_COUNT, "debug count");

        string[] memory parityRows = new string[](EVENT_COUNT);
        string[] memory ageRows = new string[](EVENT_COUNT);
        uint256 hcCount;
        uint256 emaCount;
        uint256 pythCount;

        for (uint256 i = 0; i < EVENT_COUNT; ++i) {
            EventRecorder.SwapEvent memory evt = swaps[i];
            require(evt.reason == sources[i], "reason mismatch");
            require(evt.mid == expectedMids[i], "mid mismatch");

            uint256 deltaBps = _deltaBps(evt.mid, expectedMids[i]);
            require(deltaBps == 0, "mid divergence");

            uint256 capCheck = evt.reason == REASON_PYTH ? capStrict : capSpot;

            string memory sourceLabel = _sourceLabel(evt.reason);
            parityRows[i] =
                _formatParityRow(labels[i], sourceLabel, blockNumbers[i], evt.mid, expectedMids[i], deltaBps);

            ageRows[i] = _formatAgeRow(labels[i], sourceLabel, expectedAges[i]);

            EventRecorder.ConfidenceDebugEvent memory dbg = debugEvents[i];
            require(dbg.confBlendedBps <= capCheck, "conf cap");
            if (evt.reason == REASON_NONE) {
                unchecked {
                    ++hcCount;
                }
                require(dbg.confPythBps == 0, "hc pyth conf");
            } else if (evt.reason == REASON_EMA) {
                unchecked {
                    ++emaCount;
                }
                require(dbg.confPythBps == 0, "ema pyth conf");
            } else if (evt.reason == REASON_PYTH) {
                unchecked {
                    ++pythCount;
                }
                require(dbg.confPythBps > 0, "pyth conf missing");
                require(dbg.confPythBps <= capStrict, "pyth conf cap");
            }
        }

        EventRecorder.writeCSV(
            vm,
            "metrics/mid_event_vs_precompile_mid_bps.csv",
            "label,source,block,event_mid,expected_mid,delta_bps",
            parityRows
        );
        EventRecorder.writeCSV(vm, "metrics/ageSec_hist.csv", "label,source,age_sec", ageRows);

        string[] memory sourceRows = new string[](4);
        sourceRows[0] = _formatCountRow("total", EVENT_COUNT);
        sourceRows[1] = _formatCountRow("hc", hcCount);
        sourceRows[2] = _formatCountRow("ema", emaCount);
        sourceRows[3] = _formatCountRow("pyth", pythCount);
        EventRecorder.writeCSV(vm, "metrics/source_counts.csv", "source,count", sourceRows);

        // Divergence guard sweep: run multiple deltas and capture histogram
        uint256[] memory divergenceDeltasBps = new uint256[](7);
        divergenceDeltasBps[0] = 10;
        divergenceDeltasBps[1] = 25;
        divergenceDeltasBps[2] = divergenceCap > 0 ? divergenceCap - 1 : 0;
        divergenceDeltasBps[3] = divergenceCap;
        divergenceDeltasBps[4] = divergenceCap + 10;
        divergenceDeltasBps[5] = divergenceCap + 50;
        divergenceDeltasBps[6] = 1_200;

        uint256[] memory divergenceAttemptsByDelta = new uint256[](divergenceDeltasBps.length);
        uint256[] memory divergenceRejectionsByDelta = new uint256[](divergenceDeltasBps.length);
        uint256 expectedDivergenceRejections;

        for (uint256 i = 0; i < divergenceDeltasBps.length; ++i) {
            uint256 deltaBps = divergenceDeltasBps[i];
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 1);
            updateSpot(1e18, 5, true);
            updateBidAsk(995e15, 1_005e15, 20, true);
            updateEma(1e18, 6, true);

            uint256 pythMid = (1e18 * (10_000 + deltaBps)) / 10_000;
            updatePyth(pythMid, 1e18, 5, 5, 25, 25);

            unchecked {
                ++divergenceAttempts;
                ++divergenceAttemptsByDelta[i];
            }

            bool expectsRevert = deltaBps > divergenceCap;
            if (expectsRevert) {
                vm.expectRevert(Errors.OracleDiverged.selector);
                quote(15 ether, true, IDnmPool.OracleMode.Spot);
                unchecked {
                    ++divergenceRejections;
                    ++divergenceRejectionsByDelta[i];
                    ++expectedDivergenceRejections;
                }
            } else {
                DnmPool.QuoteResult memory qrDelta = quote(15 ether, true, IDnmPool.OracleMode.Spot);
                require(!qrDelta.usedFallback, "divergence fallback");
                require(qrDelta.reason == REASON_NONE, "divergence reason");
            }
        }

        for (uint256 i = 0; i < divergenceDeltasBps.length; ++i) {
            bool shouldReject = divergenceDeltasBps[i] > divergenceCap;
            if (shouldReject) {
                require(divergenceRejectionsByDelta[i] == divergenceAttemptsByDelta[i], "divergence bin must reject");
            } else {
                require(divergenceRejectionsByDelta[i] == 0, "divergence bin should pass");
            }
        }

        string[] memory divergenceRows = new string[](3);
        divergenceRows[0] = _formatCountRow("divergence_attempts", divergenceAttempts);
        divergenceRows[1] = _formatCountRow("divergence_rejections", divergenceRejections);
        uint256 divergenceRateBps = divergenceAttempts == 0 ? 0 : (divergenceRejections * 10_000) / divergenceAttempts;
        divergenceRows[2] = _formatCountRow("divergence_reject_rate_bps", divergenceRateBps);
        EventRecorder.writeCSV(vm, "metrics/divergence_rate.csv", "metric,value", divergenceRows);

        require(divergenceRejections == expectedDivergenceRejections, "divergence rejection count");
        require(staleAttempts == staleRejections, "stale must reject");
    }

    function _pythAge() private view returns (uint256) {
        (,, uint256 ageHype, uint256 ageUsdc,,,) = oraclePyth.result();
        return ageHype > ageUsdc ? ageHype : ageUsdc;
    }

    function _deltaBps(uint256 actual, uint256 expected) private pure returns (uint256) {
        if (expected == 0) {
            return actual == 0 ? 0 : type(uint256).max;
        }
        if (actual == expected) {
            return 0;
        }
        uint256 diff = actual > expected ? actual - expected : expected - actual;
        return (diff * 10_000) / expected;
    }

    function _sourceLabel(bytes32 reason) private pure returns (string memory) {
        if (reason == REASON_NONE) return "hc";
        if (reason == REASON_EMA) return "ema";
        if (reason == REASON_PYTH) return "pyth";
        if (reason == bytes32("FLOOR")) return "floor";
        if (reason == bytes32("SPREAD")) return "spread";
        return "unknown";
    }

    function _formatParityRow(
        string memory label,
        string memory source,
        uint256 blockNumber,
        uint256 eventMid,
        uint256 expectedMid,
        uint256 deltaBps
    ) private pure returns (string memory) {
        return string.concat(
            label,
            ",",
            source,
            ",",
            EventRecorder.uintToString(blockNumber),
            ",",
            EventRecorder.uintToString(eventMid),
            ",",
            EventRecorder.uintToString(expectedMid),
            ",",
            EventRecorder.uintToString(deltaBps)
        );
    }

    function _formatAgeRow(string memory label, string memory source, uint256 ageSec)
        private
        pure
        returns (string memory)
    {
        return string.concat(label, ",", source, ",", EventRecorder.uintToString(ageSec));
    }

    function _formatCountRow(string memory name, uint256 value) private pure returns (string memory) {
        return string.concat(name, ",", EventRecorder.uintToString(value));
    }
}
