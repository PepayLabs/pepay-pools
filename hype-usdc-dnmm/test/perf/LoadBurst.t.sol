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
        uint256 iterations = 30;

        string[] memory feeRows = new string[](iterations);
        uint256 partials;
        uint256 total;
        uint256 cumulativeFeeBps;

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
            uint256 amountIn = isBaseIn ? (5 + (i % 5)) * 1 ether : (2_000_000000 + (i % 3) * 750_000000);
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

            feeRows[i] = string.concat(
                EventRecorder.uintToString(i),
                ",",
                EventRecorder.uintToString(evt.feeBps),
                ",",
                _reasonString(evt.reason)
            );

            if ((i + 1) % 6 == 0) {
                vm.roll(block.number + 2);
                vm.warp(block.timestamp + 2);
            }
        }

        uint256 failureRateBps = total == 0 ? 0 : (partials * BPS) / total;
        uint256 avgFeeBps = total == 0 ? 0 : cumulativeFeeBps / total;

        string[] memory summaryRows = new string[](4);
        summaryRows[0] = string.concat("total_swaps,", EventRecorder.uintToString(total));
        summaryRows[1] = string.concat("partial_swaps,", EventRecorder.uintToString(partials));
        summaryRows[2] = string.concat("failure_rate_bps,", EventRecorder.uintToString(failureRateBps));
        summaryRows[3] = string.concat("avg_fee_bps,", EventRecorder.uintToString(avgFeeBps));

        EventRecorder.writeCSV(vm, "metrics/load_burst_summary.csv", "metric,value", summaryRows);
        EventRecorder.writeCSV(vm, "metrics/load_fee_decay_series.csv", "iteration,fee_bps,reason", feeRows);
    }

    function _configureSpot(uint256 mid, uint256 spreadBps) internal {
        uint256 delta = (mid * spreadBps) / (2 * BPS);
        uint256 bid = mid > delta ? mid - delta : 1;
        uint256 ask = mid + delta;
        updateSpot(mid, 0, true);
        updateBidAsk(bid, ask, spreadBps, true);
        updatePyth(mid, WAD, 0, 0, 20, 20);
    }

    function _configurePythFallback(uint256 mid) internal {
        uint256 staleAge = defaultOracleConfig().maxAgeSec + 5;
        updateSpot(mid, staleAge, true);
        updateBidAsk(mid, mid, 20, true);
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

        redeployPool(invCfg, oracleCfg, feeCfg, makerCfg);
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
