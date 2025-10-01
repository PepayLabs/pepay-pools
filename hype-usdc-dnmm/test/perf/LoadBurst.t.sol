// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";

import {BaseTest} from "../utils/BaseTest.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";

contract LoadBurstPerfTest is BaseTest {
    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);
        approveAll(carol);
    }

    function test_burst_load_metrics() public {
        _freshPool();
        uint256 iterations = 5_000;

        uint256 sampleInterval = 50;
        string[] memory feeRows = new string[](iterations / sampleInterval);
        uint256 samplePtr;
        uint256 partials;
        uint256 total;
        uint256 cumulativeFeeBps;
        uint256 spreadRejects;
        uint256 staleRejects;
        uint256 divergenceRejects;

        vm.pauseGasMetering();
        for (uint256 i = 0; i < iterations; ++i) {
            bool isBaseIn = i % 2 == 0;
            uint256 spreadBps = i % 6 == 0 ? 180 : 40;
            uint256 mid = i % 10 == 0 ? 105e16 : WAD;

            if (i % 9 == 0) {
                _configureSpot(mid, spreadBps);
                updateEma(mid, 1, true);
            } else if (i % 7 == 0) {
                _configureSpot(mid, 600);
                updateEma(mid, 1, true);
            } else if (i % 11 == 0) {
                _configurePythFallback(mid);
            } else {
                _configureSpot(mid, spreadBps);
                updateEma(mid, 0, true);
            }

            vm.recordLogs();
            address trader = isBaseIn ? alice : bob;
            uint256 amountIn = isBaseIn ? (1 ether + (i % 4) * 2e17) : (350_000000 + (i % 4) * 120_000000);
            if (!isBaseIn) deal(address(usdc), trader, amountIn);
            if (isBaseIn) deal(address(hype), trader, amountIn);
            vm.prank(trader);
            pool.swapExactIn(amountIn, 0, isBaseIn, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 60);

            EventRecorder.SwapEvent[] memory swaps = drainLogsToSwapEvents();
            if (swaps.length == 0) continue;
            EventRecorder.SwapEvent memory evt = swaps[0];
            total += 1;
            if (evt.isPartial) partials += 1;
            cumulativeFeeBps += evt.feeBps;
            if (evt.reason == bytes32("SPREAD")) spreadRejects += 1;
            if (evt.reason == bytes32("STALE")) staleRejects += 1;
            if (evt.reason == bytes32("DIVERGENCE")) divergenceRejects += 1;

            if (i % sampleInterval == 0 && samplePtr < feeRows.length) {
                feeRows[samplePtr++] = string.concat(
                    EventRecorder.uintToString(i),
                    ",",
                    EventRecorder.uintToString(evt.feeBps),
                    ",",
                    _reasonString(evt.reason)
                );
            }

            if ((i + 1) % 64 == 0) {
                vm.roll(block.number + 4);
                vm.warp(block.timestamp + 4);
            }
        }
        vm.resumeGasMetering();

        uint256 criticalRejects = spreadRejects + staleRejects + divergenceRejects;
        uint256 failureRateBps = total == 0 ? 0 : (criticalRejects * BPS) / total;
        uint256 avgFeeBps = total == 0 ? 0 : cumulativeFeeBps / total;

        string[] memory summaryRows = new string[](6);
        summaryRows[0] = string.concat("total_swaps,", EventRecorder.uintToString(total));
        summaryRows[1] = string.concat("partial_swaps,", EventRecorder.uintToString(partials));
        summaryRows[2] = string.concat("spread_rejects,", EventRecorder.uintToString(spreadRejects));
        summaryRows[3] = string.concat("stale_rejects,", EventRecorder.uintToString(staleRejects));
        summaryRows[4] = string.concat("divergence_rejects,", EventRecorder.uintToString(divergenceRejects));
        summaryRows[5] = string.concat("failure_rate_bps,", EventRecorder.uintToString(failureRateBps));
        summaryRows = _append(summaryRows, "avg_fee_bps", avgFeeBps);
        summaryRows = _append(summaryRows, "fee_cap_bps", defaultFeeConfig().capBps);

        EventRecorder.writeCSV(vm, "metrics/load_burst_summary.csv", "metric,value", summaryRows);
        EventRecorder.writeCSV(vm, "metrics/load_fee_decay_series.csv", "iteration,fee_bps,reason", feeRows);
    }

    function _append(string[] memory rows, string memory key, uint256 value) internal pure returns (string[] memory) {
        string[] memory expanded = new string[](rows.length + 1);
        for (uint256 i = 0; i < rows.length; ++i) {
            expanded[i] = rows[i];
        }
        expanded[rows.length] = string.concat(key, ",", EventRecorder.uintToString(value));
        return expanded;
    }

    function _configureSpot(uint256 mid, uint256 spreadBps) internal {
        uint256 delta = (mid * spreadBps) / (2 * BPS);
        uint256 bid = mid > delta ? mid - delta : 1;
        uint256 ask = mid + delta;
        if (ask <= bid) {
            ask = bid + 1;
        }
        updateSpot(mid, 0, true);
        updateBidAsk(bid, ask, spreadBps, true);
        updatePyth(mid, WAD, 0, 0, 20, 20);
    }

    function _configurePythFallback(uint256 mid) internal {
        uint256 staleAge = defaultOracleConfig().maxAgeSec + 5;
        updateSpot(mid, staleAge, true);
        updateBidAsk(mid - 1, mid + 1, 20, true);
        updateEma(mid, staleAge, true);
        updatePyth(mid, WAD, 1, 1, 20, 20);
    }

    function _reasonString(bytes32 reason) internal pure returns (string memory) {
        if (reason == bytes32(0)) return "NONE";
        if (reason == bytes32("FLOOR")) return "FLOOR";
        if (reason == bytes32("EMA")) return "EMA";
        if (reason == bytes32("PYTH")) return "PYTH";
        if (reason == bytes32("SPREAD")) return "SPREAD";
        return "OTHER";
    }

    function _freshPool() internal {
        DnmPool.InventoryConfig memory invCfg = defaultInventoryConfig();
        DnmPool.OracleConfig memory oracleCfg = defaultOracleConfig();
        FeePolicy.FeeConfig memory feeCfg = defaultFeeConfig();
        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();

        redeployPool(invCfg, oracleCfg, feeCfg, makerCfg, defaultAomqConfig());
        seedPOL(
            DeployConfig({
                baseLiquidity: 120_000 ether,
                quoteLiquidity: 12_000_000000,
                floorBps: invCfg.floorBps,
                recenterPct: invCfg.recenterThresholdPct,
                divergenceBps: oracleCfg.divergenceBps,
                allowEmaFallback: oracleCfg.allowEmaFallback
            })
        );
        approveAll(alice);
        approveAll(bob);
        approveAll(carol);
        _seedUser(alice, 25_000 ether, 3_000_000000);
        _seedUser(bob, 20_000 ether, 2_500_000000);
        _seedUser(carol, 10_000 ether, 1_000_000000);
        _setOracleDefaults();
    }
}
