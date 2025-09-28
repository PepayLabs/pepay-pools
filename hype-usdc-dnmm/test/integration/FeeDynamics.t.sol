// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";
import {Inventory} from "../../contracts/lib/Inventory.sol";
import {FixedPointMath} from "../../contracts/lib/FixedPointMath.sol";

import {BaseTest} from "../utils/BaseTest.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";

contract FeeDynamicsTest is BaseTest {
    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);
        approveAll(carol);
    }

    function test_B1_calm_fee_at_base() public {
        _freshPool();
        FeePolicy.FeeConfig memory cfg = _feeConfig();

        _setBidAskWithSpread(WAD, 0);
        string[] memory rows = new string[](3);

        DnmPool.QuoteResult memory q1 = quote(10 ether, true, IDnmPool.OracleMode.Spot);
        rows[0] = _formatCalmRow("initial", 0, q1.feeBpsUsed, cfg.baseBps);

        vm.roll(block.number + 5);
        vm.warp(block.timestamp + 5);
        DnmPool.QuoteResult memory q2 = quote(5 ether, true, IDnmPool.OracleMode.Spot);
        rows[1] = _formatCalmRow("post_time", 0, q2.feeBpsUsed, cfg.baseBps);

        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 10);
        DnmPool.QuoteResult memory q3 = quote(5_000_000000, false, IDnmPool.OracleMode.Spot);
        rows[2] = _formatCalmRow("quote_side", 0, q3.feeBpsUsed, cfg.baseBps);

        require(q1.feeBpsUsed == cfg.baseBps, "fee should equal base in calm conditions");
        require(q2.feeBpsUsed == cfg.baseBps, "fee remains base over time");
        require(q3.feeBpsUsed == cfg.baseBps, "fee base on quote leg");

        EventRecorder.writeCSV(vm, "metrics/fee_B1_calm.csv", "label,spread_bps,fee_bps,base_fee_bps", rows);
    }

    function test_B2_volatility_term_increases_fee() public {
        _freshPool();
        FeePolicy.FeeConfig memory cfg = _feeConfig();

        uint256[] memory spreadSteps = new uint256[](6);
        spreadSteps[0] = 0;
        spreadSteps[1] = 10;
        spreadSteps[2] = 25;
        spreadSteps[3] = 50;
        spreadSteps[4] = 100;
        spreadSteps[5] = 200;

        uint256 confCap = defaultOracleConfig().confCapBpsSpot;

        string[] memory rows = new string[](spreadSteps.length);
        uint256[] memory confSeries = new uint256[](spreadSteps.length);
        uint256[] memory invSeries = new uint256[](spreadSteps.length);
        uint256[] memory observedFees = new uint256[](spreadSteps.length);

        for (uint256 i = 0; i < spreadSteps.length; ++i) {
            _setBidAskWithSpread(WAD, spreadSteps[i]);
            DnmPool.QuoteResult memory quoteRes = quote(10 ether, true, IDnmPool.OracleMode.Spot);
            observedFees[i] = quoteRes.feeBpsUsed;
            uint256 effectiveConf = spreadSteps[i] > confCap ? confCap : spreadSteps[i];
            confSeries[i] = effectiveConf;
            invSeries[i] = 0;
            if (i > 0) {
                require(observedFees[i] >= observedFees[i - 1], "fee must be non-decreasing vs spread");
            }
            rows[i] = _formatSpreadRow(spreadSteps[i], observedFees[i]);
        }

        EventRecorder.FeeComponentSeries memory series = EventRecorder.computeFeeComponents(cfg, confSeries, invSeries);
        require(series.totalFeeBps.length == observedFees.length, "component length");
        for (uint256 i = 0; i < series.totalFeeBps.length; ++i) {
            require(series.totalFeeBps[i] == observedFees[i], "component mismatch");
        }

        EventRecorder.writeCSV(vm, "metrics/fee_B2_spread_series.csv", "spread_bps,fee_bps", rows);
    }

    function test_B3_inventory_term_increases_fee() public {
        uint256[] memory targetDeviationBps = new uint256[](5);
        targetDeviationBps[0] = 0;
        targetDeviationBps[1] = 100;
        targetDeviationBps[2] = 300;
        targetDeviationBps[3] = 500;
        targetDeviationBps[4] = 800;

        string[] memory rows = new string[](targetDeviationBps.length);
        uint256[] memory confSeries = new uint256[](targetDeviationBps.length);
        uint256[] memory invSeries = new uint256[](targetDeviationBps.length);
        uint256[] memory observed = new uint256[](targetDeviationBps.length);

        for (uint256 i = 0; i < targetDeviationBps.length; ++i) {
            _freshPool();
            FeePolicy.FeeConfig memory cfg = _feeConfig();
            _setBidAskWithSpread(WAD, 40);
            _induceInventoryDeviationPositive(targetDeviationBps[i]);

            DnmPool.QuoteResult memory q = quote(10 ether, true, IDnmPool.OracleMode.Spot);
            uint256 deviationBps = _currentInventoryDeviationBps(q.midUsed);
            observed[i] = q.feeBpsUsed;
            confSeries[i] = 40;
            invSeries[i] = deviationBps;
            if (i > 0) {
                require(observed[i] >= observed[i - 1], "fee must be non-decreasing vs inv deviation");
            }
            rows[i] = _formatInventoryRow(deviationBps, q.feeBpsUsed, cfg.baseBps);
        }

        FeePolicy.FeeConfig memory cfgFinal = _feeConfig();
        EventRecorder.FeeComponentSeries memory series =
            EventRecorder.computeFeeComponents(cfgFinal, confSeries, invSeries);
        for (uint256 i = 0; i < series.totalFeeBps.length; ++i) {
            require(series.totalFeeBps[i] == observed[i], "inventory component mismatch");
        }

        EventRecorder.writeCSV(vm, "metrics/fee_B3_inventory_series.csv", "inventory_bps,fee_bps,base_fee_bps", rows);
    }

    function test_B4_fee_decay_curve_matches_config() public {
        _freshPool();
        FeePolicy.FeeConfig memory cfg = _feeConfig();

        _setBidAskWithSpread(WAD, 400);
        DnmPool.QuoteResult memory spikeQuote = quote(20 ether, true, IDnmPool.OracleMode.Spot);
        require(spikeQuote.feeBpsUsed > cfg.baseBps, "initial fee should spike");

        vm.prank(alice);
        pool.swapExactIn(5 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        _setBidAskWithSpread(WAD, 25);

        string[] memory rows = new string[](6);
        uint64 spikeBlock = uint64(block.number);
        (uint128 targetBase,,) = pool.inventoryConfig();
        (,,,, uint256 baseScale, uint256 quoteScale) = pool.tokenConfig();
        Inventory.Tokens memory tokens = Inventory.Tokens({baseScale: baseScale, quoteScale: quoteScale});
        FeePolicy.FeeState memory state =
            FeePolicy.FeeState({lastBlock: spikeBlock, lastFeeBps: uint16(spikeQuote.feeBpsUsed)});

        for (uint256 offset = 1; offset <= 6; ++offset) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 1);
            DnmPool.QuoteResult memory q = quote(1 ether, true, IDnmPool.OracleMode.Spot);
            (uint128 baseRes, uint128 quoteRes) = pool.reserves();
            uint256 invDev = Inventory.deviationBps(uint256(baseRes), uint256(quoteRes), targetBase, q.midUsed, tokens);
            uint256 invComponent = cfg.betaInvDevDenominator == 0
                ? 0
                : FixedPointMath.mulDivDown(invDev, cfg.betaInvDevNumerator, cfg.betaInvDevDenominator);
            uint256 confComponent =
                q.feeBpsUsed > cfg.baseBps + invComponent ? q.feeBpsUsed - cfg.baseBps - invComponent : 0;
            uint256 confBps = cfg.alphaConfNumerator == 0
                ? 0
                : FixedPointMath.mulDivDown(confComponent, cfg.alphaConfDenominator, cfg.alphaConfNumerator);
            (uint16 expectedFee, FeePolicy.FeeState memory newState) =
                FeePolicy.preview(state, cfg, confBps, invDev, block.number);
            require(_withinTolerance(q.feeBpsUsed, expectedFee, 1), "fee should follow decay curve");
            state = newState;
            rows[offset - 1] = _formatDecayRow(offset, q.feeBpsUsed, expectedFee);
        }

        EventRecorder.writeCSV(vm, "metrics/fee_B4_decay_series.csv", "block_offset,fee_bps,expected_bps", rows);
    }

    function test_B5_confidence_fee_correlation_exceeds_threshold() public {
        _freshPool();
        enableBlend();
        FeePolicy.FeeConfig memory cfg = _feeConfig();

        uint256 sampleCount = 9;
        uint256[] memory observedFees = new uint256[](sampleCount);
        uint256[] memory confSeries = new uint256[](sampleCount);
        string[] memory rows = new string[](sampleCount + 1);

        vm.recordLogs();

        for (uint256 i = 0; i < sampleCount; ++i) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 1);
            uint256 spread = 10 + i * 20;
            uint256 mid = WAD + (i * 5e14);
            _setBidAskWithSpread(mid, spread);
            DnmPool.QuoteResult memory quoteRes = quote(10 ether, true, IDnmPool.OracleMode.Spot);
            observedFees[i] = quoteRes.feeBpsUsed;
        }

        EventRecorder.ConfidenceDebugEvent[] memory debugEvents =
            EventRecorder.decodeConfidenceDebug(vm.getRecordedLogs());
        require(debugEvents.length == sampleCount, "debug event count");

        for (uint256 i = 0; i < sampleCount; ++i) {
            confSeries[i] = debugEvents[i].confBlendedBps;
            rows[i] = _formatCorrelationRow(i, confSeries[i], observedFees[i]);
            require(debugEvents[i].feeTotalBps == observedFees[i], "fee total mismatch");

            uint256 expectedVol =
                cfg.alphaConfDenominator == 0 ? 0 : (confSeries[i] * cfg.alphaConfNumerator) / cfg.alphaConfDenominator;
            require(_withinTolerance(debugEvents[i].feeVolBps, expectedVol, 1), "feeVol deviates from alpha*conf");
            require(debugEvents[i].feeBaseBps == cfg.baseBps, "base component mismatch");
            require(debugEvents[i].feeInvBps == 0, "inventory component should be zero");
        }

        int256 corrBps = EventRecorder.computePearsonCorrelation(confSeries, observedFees);
        require(corrBps >= 8000, "correlation below threshold");

        rows[sampleCount] = _formatCorrelationSummary(corrBps);
        EventRecorder.writeCSV(vm, "metrics/fee_correlation.csv", "step,conf_bps,fee_bps", rows);
    }

    function test_B6_confidence_cap_edge_behavior() public {
        DnmPool.InventoryConfig memory invCfg = defaultInventoryConfig();
        DnmPool.OracleConfig memory oracleCfg = defaultOracleConfig();
        oracleCfg.confCapBpsSpot = 400;
        oracleCfg.confCapBpsStrict = 250;

        FeePolicy.FeeConfig memory feeCfg = defaultFeeConfig();
        feeCfg.capBps = 150;

        redeployPool(invCfg, oracleCfg, feeCfg, defaultMakerConfig());
        seedPOL(
            DeployConfig({
                baseLiquidity: 100_000 ether,
                quoteLiquidity: 10_000_000000,
                floorBps: invCfg.floorBps,
                recenterPct: invCfg.recenterThresholdPct,
                divergenceBps: oracleCfg.divergenceBps,
                allowEmaFallback: oracleCfg.allowEmaFallback
            })
        );
        approveAll(alice);
        approveAll(bob);
        approveAll(carol);
        enableBlend();

        FeePolicy.FeeConfig memory cfgAfter = _feeConfig();

        vm.recordLogs();

        _setBidAskWithSpread(WAD, 40);
        DnmPool.QuoteResult memory calmQuote = quote(5 ether, true, IDnmPool.OracleMode.Spot);
        require(calmQuote.feeBpsUsed < feeCfg.capBps, "baseline should be below cap");

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        _setBidAskWithSpread(WAD, 320);
        vm.prank(alice);
        pool.swapExactIn(20 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        uint256 postMeasurements = 5;
        uint256 entryCount = postMeasurements + 2; // baseline + swap + post samples
        string[] memory labels = new string[](entryCount);
        uint256[] memory spreads = new uint256[](entryCount);

        labels[0] = "baseline";
        spreads[0] = 40;

        labels[1] = "swap_peak";
        spreads[1] = 320;

        for (uint256 i = 0; i < postMeasurements; ++i) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 1);
            uint256 spread = i % 2 == 0 ? 160 : 80;
            _setBidAskWithSpread(WAD, spread);
            DnmPool.QuoteResult memory res = quote(5 ether, true, IDnmPool.OracleMode.Spot);
            require(res.feeBpsUsed <= feeCfg.capBps, "fee exceeded cap");
            labels[i + 2] = string.concat("post_", EventRecorder.uintToString(i));
            spreads[i + 2] = spread;
        }

        EventRecorder.ConfidenceDebugEvent[] memory debugEvents =
            EventRecorder.decodeConfidenceDebug(vm.getRecordedLogs());
        require(debugEvents.length == entryCount, "cap debug events mismatch");

        require(debugEvents[0].feeTotalBps == calmQuote.feeBpsUsed, "baseline fee mismatch");
        require(debugEvents[0].feeBaseBps == cfgAfter.baseBps, "baseline base component mismatch");
        require(debugEvents[1].feeTotalBps == feeCfg.capBps, "swap should hit cap exactly");
        uint256 expectedSwapVol = cfgAfter.alphaConfDenominator == 0
            ? 0
            : (debugEvents[1].confBlendedBps * cfgAfter.alphaConfNumerator) / cfgAfter.alphaConfDenominator;
        require(_withinTolerance(debugEvents[1].feeVolBps, expectedSwapVol, 1), "swap vol mismatch");

        string[] memory csvRows = new string[](entryCount + 1);
        csvRows[0] = _formatCapEdgeRow(labels[0], spreads[0], debugEvents[0].confBlendedBps, debugEvents[0].feeTotalBps);
        for (uint256 i = 1; i < entryCount; ++i) {
            EventRecorder.ConfidenceDebugEvent memory evt = debugEvents[i];
            require(evt.feeTotalBps <= feeCfg.capBps, "event fee above cap");
            require(evt.feeBaseBps == cfgAfter.baseBps, "base component drift");
            uint256 expectedVol = cfgAfter.alphaConfDenominator == 0
                ? 0
                : (evt.confBlendedBps * cfgAfter.alphaConfNumerator) / cfgAfter.alphaConfDenominator;
            require(_withinTolerance(evt.feeVolBps, expectedVol, 1), "vol component mismatch");
            csvRows[i] = _formatCapEdgeRow(labels[i], spreads[i], evt.confBlendedBps, evt.feeTotalBps);
        }

        csvRows[entryCount] = _formatCapEdgeRow("cap", feeCfg.capBps, feeCfg.capBps, feeCfg.capBps);
        EventRecorder.writeCSV(vm, "metrics/fee_cap_edge.csv", "label,spread_bps,conf_bps,fee_bps", csvRows);
    }

    // --- helpers ---

    function _withinTolerance(uint256 actual, uint256 expected, uint256 tolerance) internal pure returns (bool) {
        if (actual > expected) {
            return actual - expected <= tolerance;
        }
        return expected - actual <= tolerance;
    }

    function _formatCalmRow(string memory label, uint256 spreadBps, uint256 feeBps, uint256 baseFee)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            label,
            ",",
            EventRecorder.uintToString(spreadBps),
            ",",
            EventRecorder.uintToString(feeBps),
            ",",
            EventRecorder.uintToString(baseFee)
        );
    }

    function _formatSpreadRow(uint256 spreadBps, uint256 feeBps) internal pure returns (string memory) {
        return string.concat(EventRecorder.uintToString(spreadBps), ",", EventRecorder.uintToString(feeBps));
    }

    function _formatInventoryRow(uint256 deviationBps, uint256 feeBps, uint256 baseFee)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            EventRecorder.uintToString(deviationBps),
            ",",
            EventRecorder.uintToString(feeBps),
            ",",
            EventRecorder.uintToString(baseFee)
        );
    }

    function _formatDecayRow(uint256 offset, uint256 actualFee, uint256 expectedFee)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            EventRecorder.uintToString(offset),
            ",",
            EventRecorder.uintToString(actualFee),
            ",",
            EventRecorder.uintToString(expectedFee)
        );
    }

    function _formatCorrelationRow(uint256 step, uint256 confBps, uint256 feeBps)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            EventRecorder.uintToString(step),
            ",",
            EventRecorder.uintToString(confBps),
            ",",
            EventRecorder.uintToString(feeBps)
        );
    }

    function _formatCorrelationSummary(int256 corrBps) internal pure returns (string memory) {
        return string.concat("correlation,", EventRecorder.intToString(corrBps), ",");
    }

    function _formatCapEdgeRow(string memory label, uint256 spreadBps, uint256 confBps, uint256 feeBps)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            label,
            ",",
            EventRecorder.uintToString(spreadBps),
            ",",
            EventRecorder.uintToString(confBps),
            ",",
            EventRecorder.uintToString(feeBps)
        );
    }

    function _currentInventoryDeviationBps(uint256 mid) internal view returns (uint256) {
        (uint128 baseRes, uint128 quoteRes) = pool.reserves();
        (uint128 targetBase,,) = pool.inventoryConfig();
        (,,,, uint256 baseScale, uint256 quoteScale) = pool.tokenConfig();
        Inventory.Tokens memory tokens = Inventory.Tokens({baseScale: baseScale, quoteScale: quoteScale});
        return Inventory.deviationBps(baseRes, quoteRes, targetBase, mid, tokens);
    }

    function _feeConfig() internal view returns (FeePolicy.FeeConfig memory cfg) {
        (
            uint16 baseBps,
            uint16 alphaConfNumerator,
            uint16 alphaConfDenominator,
            uint16 betaInvDevNumerator,
            uint16 betaInvDevDenominator,
            uint16 capBps,
            uint16 decayPctPerBlock
        ) = pool.feeConfig();
        cfg = FeePolicy.FeeConfig({
            baseBps: baseBps,
            alphaConfNumerator: alphaConfNumerator,
            alphaConfDenominator: alphaConfDenominator,
            betaInvDevNumerator: betaInvDevNumerator,
            betaInvDevDenominator: betaInvDevDenominator,
            capBps: capBps,
            decayPctPerBlock: decayPctPerBlock
        });
    }

    function _induceInventoryDeviationPositive(uint256 deviationBps) internal {
        if (deviationBps == 0) return;
        (uint128 baseRes,) = pool.reserves();
        uint256 extra = (uint256(baseRes) * deviationBps) / BPS;
        if (extra == 0) extra = 1;
        deal(address(hype), alice, extra);
        vm.prank(alice);
        pool.swapExactIn(extra, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
    }

    function _setBidAskWithSpread(uint256 mid, uint256 spreadBps) internal {
        uint256 delta = (mid * spreadBps) / (2 * BPS);
        uint256 bid = mid > delta ? mid - delta : 1;
        uint256 ask = mid + delta;
        if (ask <= bid) {
            ask = bid + 1;
        }
        updateSpot(mid, 0, true);
        updateBidAsk(bid, ask, spreadBps, true);
        uint64 conf = uint64(spreadBps);
        updatePyth(mid, WAD, 0, 0, conf, conf);
    }

    function _freshPool() internal {
        DnmPool.InventoryConfig memory invCfg = defaultInventoryConfig();
        DnmPool.OracleConfig memory oracleCfg = defaultOracleConfig();
        FeePolicy.FeeConfig memory feeCfg = defaultFeeConfig();
        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();

        redeployPool(invCfg, oracleCfg, feeCfg, makerCfg);
        seedPOL(
            DeployConfig({
                baseLiquidity: 100_000 ether,
                quoteLiquidity: 10_000_000000,
                floorBps: invCfg.floorBps,
                recenterPct: invCfg.recenterThresholdPct,
                divergenceBps: oracleCfg.divergenceBps,
                allowEmaFallback: oracleCfg.allowEmaFallback
            })
        );
        approveAll(alice);
        approveAll(bob);
        approveAll(carol);
    }
}
