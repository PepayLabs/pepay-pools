// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {OracleUtils} from "../../contracts/lib/OracleUtils.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {DnmOracleObserver} from "../../contracts/observer/DnmOracleObserver.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract ScenarioCanaryShadowTest is BaseTest {
    bytes32 private constant LABEL_HC = bytes32("hc_live");
    bytes32 private constant LABEL_EMA = bytes32("ema_fallback");
    bytes32 private constant LABEL_PYTH = bytes32("pyth_fallback");
    bytes32 private constant LABEL_DIV = bytes32("divergence");

    DnmOracleObserver internal observer;

    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);
        enableBlend();

        observer = new DnmOracleObserver(oracleHC, oraclePyth);
    }

    function test_canary_observer_tracks_pool_paths() public {
        (,,,, uint16 divergenceBps,,,,,) = pool.oracleConfig();

        bytes32[4] memory labels = [LABEL_HC, LABEL_EMA, LABEL_PYTH, LABEL_DIV];
        uint256[] memory deltas = new uint256[](labels.length - 1); // exclude divergence rejection from median
        uint256 deltaPtr;
        uint256 rejectionSnapshots;
        uint256 rejectionCount;

        string[] memory rows = new string[](labels.length);

        for (uint256 i = 0; i < labels.length; ++i) {
            bytes32 label = labels[i];
            bool expectRevert = label == LABEL_DIV;
            uint256 currentBlock = block.number;
            uint256 amountIn = 1 ether;

            _configureScenario(label);

            DnmPool.QuoteResult memory preview;
            if (!expectRevert) {
                preview = quote(amountIn, true, IDnmPool.OracleMode.Spot);
            }

            vm.recordLogs();
            observer.snapshot(label);

            if (expectRevert) {
                (uint256 hcMid,,) = oracleHC.spot();
                (uint256 pythMid,,,,,,) = oraclePyth.result();
                uint256 expectedDelta = OracleUtils.computeDivergenceBps(hcMid, pythMid);
                rejectionCount += 1;
                vm.prank(alice);
                vm.expectRevert(abi.encodeWithSelector(Errors.OracleDiverged.selector, expectedDelta, divergenceBps));
                pool.swapExactIn(amountIn, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 10);
            } else {
                swap(alice, amountIn, 0, true, IDnmPool.OracleMode.Spot, block.timestamp + 10);
            }

            Vm.Log[] memory logs = vm.getRecordedLogs();
            EventRecorder.OracleSnapshotEvent[] memory snapshots = EventRecorder.decodeOracleSnapshots(logs);
            require(snapshots.length == 1, "snapshot emitted");
            EventRecorder.OracleSnapshotEvent memory snap = snapshots[0];
            require(snap.label == label, "label mismatch");
            if (label != LABEL_PYTH) {
                require(snap.hcSuccess, "hc success");
                require(snap.bookSuccess, "book success");
            }

            if (expectRevert) {
                if (snap.deltaBps > divergenceBps) {
                    rejectionSnapshots += 1;
                }
                rows[i] = _formatCanaryRow(label, currentBlock, snap.mid, snap.pythMid, snap.deltaBps, "REJECTED");
                continue;
            }

            EventRecorder.SwapEvent[] memory swaps = EventRecorder.decodeSwapEvents(logs);
            require(swaps.length == 1, "swap emitted");
            EventRecorder.SwapEvent memory swapEvt = swaps[0];

            if (label == LABEL_PYTH) {
                require(snap.deltaBps == 0, "pyth delta zero");
                require(snap.pythSuccess, "pyth success required");
                require(preview.usedFallback, "pyth fallback");
                require(preview.midUsed == snap.mid, "pyth mid match");
                require(!snap.hcSuccess, "pyth hc disabled");
                require(swapEvt.reason == bytes32("PYTH"), "pyth reason");
            } else if (label == LABEL_EMA) {
                require(snap.deltaBps <= divergenceBps, "ema delta bounded");
                require(preview.usedFallback, "ema fallback");
                require(swapEvt.reason == bytes32("EMA"), "ema reason");
            } else {
                require(snap.deltaBps <= divergenceBps, "hc delta bounded");
                require(swapEvt.mid == snap.mid, "hc parity");
                require(swapEvt.reason == bytes32(0), "hc reason");
            }

            deltas[deltaPtr++] = snap.deltaBps;
            rows[i] = _formatCanaryRow(
                label, currentBlock, swapEvt.mid, snap.pythMid, snap.deltaBps, _reasonString(swapEvt.reason)
            );
        }

        require(rejectionSnapshots == rejectionCount, "rejection correlation");
        uint256 medianDelta = _median(deltas, deltaPtr);
        require(medianDelta <= divergenceBps, "median within epsilon");

        EventRecorder.writeCSV(vm, "metrics/canary_deltas.csv", "label,block,swap_mid,pyth_mid,delta_bps,reason", rows);
    }

    function _configureScenario(bytes32 label) internal {
        if (label == LABEL_HC) {
            updateSpot(1_002e18, 3, true);
            updateBidAsk(998e16, 1006e16, 40, true);
            updateEma(1_001e18, 4, true);
            updatePyth(1_001e18, 1e18, 2, 2, 35, 32);
            return;
        }

        if (label == LABEL_EMA) {
            updateSpot(1_005e18, 4, true);
            updateBidAsk(985e16, 1_025e18, 220, true);
            updateEma(1_000e18, 5, true);
            updatePyth(1_004e18, 1e18, 4, 4, 40, 38);
            return;
        }

        if (label == LABEL_PYTH) {
            updateSpot(0, 0, false);
            updateBidAsk(0, 0, 0, false);
            updateEma(0, 120, false);
            updatePyth(1_020e18, 1e18, 3, 3, 55, 50);
            return;
        }

        // divergence scenario
        updateSpot(1_000e18, 2, true);
        updateBidAsk(995e16, 1_005e18, 20, true);
        updateEma(1_000e18, 3, true);
        updatePyth(1_120e18, 1e18, 2, 2, 35, 35);
    }

    function _median(uint256[] memory arr, uint256 length) internal pure returns (uint256) {
        if (length == 0) return 0;
        for (uint256 i = 0; i < length; ++i) {
            for (uint256 j = i + 1; j < length; ++j) {
                if (arr[j] < arr[i]) {
                    (arr[i], arr[j]) = (arr[j], arr[i]);
                }
            }
        }
        if (length % 2 == 1) {
            return arr[length / 2];
        }
        uint256 midUpper = arr[length / 2];
        uint256 midLower = arr[length / 2 - 1];
        return (midUpper + midLower) / 2;
    }

    function _reasonString(bytes32 reason) internal pure returns (string memory) {
        if (reason == bytes32(0)) return "NONE";
        if (reason == bytes32("EMA")) return "EMA";
        if (reason == bytes32("PYTH")) return "PYTH";
        if (reason == bytes32("FLOOR")) return "FLOOR";
        if (reason == bytes32("SPREAD")) return "SPREAD";
        if (reason == bytes32("DIVERGENCE")) return "DIVERGENCE";
        return "UNKNOWN";
    }

    function _formatCanaryRow(
        bytes32 label,
        uint256 blockNumber,
        uint256 swapMid,
        uint256 pythMid,
        uint256 deltaBps,
        string memory reason
    ) internal pure returns (string memory) {
        return string.concat(
            _labelString(label),
            ",",
            EventRecorder.uintToString(blockNumber),
            ",",
            EventRecorder.uintToString(swapMid),
            ",",
            EventRecorder.uintToString(pythMid),
            ",",
            EventRecorder.uintToString(deltaBps),
            ",",
            reason
        );
    }

    function _labelString(bytes32 label) internal pure returns (string memory) {
        if (label == LABEL_HC) return "hc_live";
        if (label == LABEL_EMA) return "ema_fallback";
        if (label == LABEL_PYTH) return "pyth_fallback";
        if (label == LABEL_DIV) return "divergence";
        return "unknown";
    }
}
