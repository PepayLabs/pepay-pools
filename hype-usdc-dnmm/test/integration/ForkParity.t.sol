// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract ForkParityTest is BaseTest {
    bytes32 private constant REASON_NONE = bytes32(0);
    bytes32 private constant REASON_EMA = bytes32("EMA");
    bytes32 private constant REASON_PYTH = bytes32("PYTH");
    uint256 private constant EVENT_COUNT = 3;

    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);
        approveAll(carol);
    }

    function test_fork_parity_paths_and_metrics() public {
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

        // FP3: Pyth fallback when HC path unavailable and EMA stale
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        updateSpot(0, 0, false);
        updateBidAsk(0, 0, 0, false);
        updateEma(0, 40, false);
        updatePyth(1_030_000_000_000_000_000, 1e18, 4, 6, 30, 28);

        labels[idx] = "pyth_fallback";
        sources[idx] = REASON_PYTH;
        expectedMids[idx] = 1_030_000_000_000_000_000;
        expectedAges[idx] = _pythAge();
        blockNumbers[idx] = block.number;
        swap(carol, 8 ether, 0, true, IDnmPool.OracleMode.Spot, block.timestamp + 5);

        // Divergence guard: HC fresh but deviates from Pyth beyond epsilon
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        updateSpot(1e18, 5, true);
        updateBidAsk(995e15, 1_005e15, 20, true);
        updateEma(1e18, 6, true);
        updatePyth(1_120_000_000_000_000_000, 1e18, 5, 5, 25, 25);
        unchecked {
            ++divergenceAttempts;
        }
        vm.expectRevert(bytes(Errors.ORACLE_DIVERGENCE));
        quote(15 ether, true, IDnmPool.OracleMode.Spot);
        unchecked {
            ++divergenceRejections;
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
        vm.expectRevert(bytes(Errors.ORACLE_STALE));
        quote(10 ether, true, IDnmPool.OracleMode.Spot);
        unchecked {
            ++staleRejections;
        }

        EventRecorder.SwapEvent[] memory swaps = drainLogsToSwapEvents();
        require(swaps.length == EVENT_COUNT, "swap count");

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

            string memory sourceLabel = _sourceLabel(evt.reason);
            parityRows[i] = _formatParityRow(
                labels[i],
                sourceLabel,
                blockNumbers[i],
                evt.mid,
                expectedMids[i],
                deltaBps
            );

            ageRows[i] = _formatAgeRow(labels[i], sourceLabel, expectedAges[i]);

            if (evt.reason == REASON_NONE) {
                unchecked {
                    ++hcCount;
                }
            } else if (evt.reason == REASON_EMA) {
                unchecked {
                    ++emaCount;
                }
            } else if (evt.reason == REASON_PYTH) {
                unchecked {
                    ++pythCount;
                }
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

        string[] memory divergenceRows = new string[](3);
        divergenceRows[0] = _formatCountRow("divergence_attempts", divergenceAttempts);
        divergenceRows[1] = _formatCountRow("divergence_rejections", divergenceRejections);
        uint256 divergenceRateBps = divergenceAttempts == 0
            ? 0
            : (divergenceRejections * 10_000) / divergenceAttempts;
        divergenceRows[2] = _formatCountRow("divergence_reject_rate_bps", divergenceRateBps);
        EventRecorder.writeCSV(vm, "metrics/divergence_rate.csv", "metric,value", divergenceRows);

        require(divergenceAttempts == divergenceRejections, "divergence must reject");
        require(staleAttempts == staleRejections, "stale must reject");
    }

    function _pythAge() private view returns (uint256) {
        (, , uint256 ageHype, uint256 ageUsdc, , ,) = oraclePyth.result();
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
