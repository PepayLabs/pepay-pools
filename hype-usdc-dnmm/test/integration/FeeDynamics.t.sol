// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";
import {Inventory} from "../../contracts/lib/Inventory.sol";

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
        pool.swapExactIn(20 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        _setBidAskWithSpread(WAD, 25);

        string[] memory rows = new string[](6);
        uint64 spikeBlock = uint64(block.number);

        for (uint256 offset = 1; offset <= 6; ++offset) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 1);
            FeePolicy.FeeState memory state =
                FeePolicy.FeeState({lastBlock: spikeBlock, lastFeeBps: uint16(spikeQuote.feeBpsUsed)});
            (uint16 expectedFee,) = FeePolicy.preview(state, cfg, 25, 0, block.number);
            DnmPool.QuoteResult memory q = quote(1 ether, true, IDnmPool.OracleMode.Spot);
            require(_withinTolerance(q.feeBpsUsed, expectedFee, 3), "fee should follow decay curve");
            rows[offset - 1] = _formatDecayRow(offset, q.feeBpsUsed, expectedFee);
        }

        EventRecorder.writeCSV(vm, "metrics/fee_B4_decay_series.csv", "block_offset,fee_bps,expected_bps", rows);
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
