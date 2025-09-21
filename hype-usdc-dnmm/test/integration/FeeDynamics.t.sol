// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";

contract FeeDynamicsTest is BaseTest {
    uint256 private constant BPS = 10_000;
    uint256 private constant BASE = 1e18;
    uint256 private constant BASE_TO_QUOTE_SCALE = 1e12; // convert base reserve deltas to quote notionals

    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);
    }

    function test_B1_calm_fee_at_base() public {
        _setBidAskWithSpread(BASE, 0);
        DnmPool.QuoteResult memory q1 = quote(10 ether, true, IDnmPool.OracleMode.Spot);
        (uint16 baseFee,,,,,,) = pool.feeConfig();
        assertEq(q1.feeBpsUsed, baseFee, "fee should equal base in calm conditions");

        DnmPool.QuoteResult memory q2 = quote(10_000000, false, IDnmPool.OracleMode.Spot);
        assertEq(q2.feeBpsUsed, baseFee, "fee should remain at base");

        vm.roll(block.number + 5);
        vm.warp(block.timestamp + 5);
        DnmPool.QuoteResult memory q3 = quote(10 ether, true, IDnmPool.OracleMode.Spot);
        assertEq(q3.feeBpsUsed, baseFee, "fee remains base after time elapses");
    }

    function test_B2_volatility_term_increases_fee() public {
        uint256[] memory spreadSteps = new uint256[](5);
        spreadSteps[0] = 0;
        spreadSteps[1] = 25;
        spreadSteps[2] = 50;
        spreadSteps[3] = 100;
        spreadSteps[4] = 200;

        uint256[] memory fees = new uint256[](spreadSteps.length);
        for (uint256 i = 0; i < spreadSteps.length; ++i) {
            _setBidAskWithSpread(BASE, spreadSteps[i]);
            DnmPool.QuoteResult memory quoteRes = quote(10 ether, true, IDnmPool.OracleMode.Spot);
            fees[i] = quoteRes.feeBpsUsed;
            if (i > 0) {
                assertGe(fees[i], fees[i - 1], "fee must be non-decreasing vs spread");
            }
        }

        _writeSpreadSeriesCSV("metrics/fee_spread_series.csv", spreadSteps, fees);
    }

    function test_B3_inventory_term_increases_fee() public {
        uint256[] memory deviationsBps = new uint256[](5);
        deviationsBps[0] = 0;
        deviationsBps[1] = 100;
        deviationsBps[2] = 300;
        deviationsBps[3] = 500;
        deviationsBps[4] = 1000;

        uint256[] memory fees = new uint256[](deviationsBps.length);

        for (uint256 i = 0; i < deviationsBps.length; ++i) {
            _freshPool();
            _setBidAskWithSpread(BASE, 50);
            _induceInventoryDeviationPositive(deviationsBps[i]);
            DnmPool.QuoteResult memory quoteRes = quote(10 ether, true, IDnmPool.OracleMode.Spot);
            fees[i] = quoteRes.feeBpsUsed;
            if (i > 0) {
                assertGe(fees[i], fees[i - 1], "fee must be non-decreasing vs inv deviation");
            }
        }

        _writeSpreadSeriesCSV("metrics/fee_inventory_series.csv", deviationsBps, fees);
    }

    function test_B4_fee_decay_curve_matches_config() public {
        _freshPool();
        _setBidAskWithSpread(BASE, 400);
        DnmPool.QuoteResult memory spikeQuote = quote(20 ether, true, IDnmPool.OracleMode.Spot);
        (uint16 baseFee,,,,,, uint16 decayPct) = pool.feeConfig();
        assertGt(spikeQuote.feeBpsUsed, baseFee, "initial fee should spike");

        vm.prank(alice);
        pool.swapExactIn(20 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        _setBidAskWithSpread(BASE, 25);

        uint256 currentFee = spikeQuote.feeBpsUsed;
        string memory rows;
        rows = string(abi.encodePacked("block_offset,fee_bps\n"));

        for (uint256 offset = 1; offset <= 6; ++offset) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 1);
            vm.prank(bob);
            pool.swapExactIn(1 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

            DnmPool.QuoteResult memory q = quote(1 ether, true, IDnmPool.OracleMode.Spot);
            uint256 expectedNumerator = (currentFee - baseFee) * (uint256(100 - decayPct));
            uint256 expected = baseFee + expectedNumerator / 100;
            assertBetween(q.feeBpsUsed, expected, 3, "fee should follow decay curve");
            currentFee = q.feeBpsUsed;

            rows = string(abi.encodePacked(rows, _u(offset), ",", _u(q.feeBpsUsed), "\n"));
        }

        _writeCSV("metrics/fee_decay_series.csv", rows);
    }

    // --- helpers ---

    function _induceInventoryDeviation(uint256 deviationBps) internal {
        if (deviationBps == 0) return;
        (uint128 currentBase,) = pool.reserves();
        (uint128 targetBase,,) = pool.inventoryConfig();

        if (currentBase > targetBase) {
            uint256 delta = uint256(currentBase) - targetBase;
            vm.prank(alice);
            pool.swapExactIn(delta, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        } else {
            uint256 delta = uint256(targetBase) - currentBase;
            vm.prank(bob);
            pool.swapExactIn(delta * BASE_TO_QUOTE_SCALE / BASE, 0, false, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        }

        if (deviationBps == 0) return;
        uint256 desiredBase = (uint256(pool.reserves().baseReserves) * (BPS + deviationBps)) / BPS;
        if (desiredBase > uint256(pool.reserves().baseReserves)) {
            uint256 extra = desiredBase - uint256(pool.reserves().baseReserves);
            deal(address(hype), alice, extra);
            vm.prank(alice);
            pool.swapExactIn(extra, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        } else {
            uint256 extra = uint256(pool.reserves().baseReserves) - desiredBase;
            uint256 quoteAmount = (extra * BASE_TO_QUOTE_SCALE) / BASE;
            deal(address(usdc), bob, quoteAmount);
            vm.prank(bob);
            pool.swapExactIn(quoteAmount, 0, false, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        }
    }

    function _resetInventory() internal {
        (uint128 baseRes,) = pool.reserves();
        (uint128 targetBase,,) = pool.inventoryConfig();
        if (baseRes > targetBase) {
            uint256 extra = uint256(baseRes) - targetBase;
            uint256 quoteAmount = (extra * BASE_TO_QUOTE_SCALE) / BASE;
            deal(address(usdc), bob, quoteAmount);
            vm.prank(bob);
            pool.swapExactIn(quoteAmount, 0, false, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        } else if (baseRes < targetBase) {
            uint256 deficit = uint256(targetBase) - baseRes;
            deal(address(hype), alice, deficit);
            vm.prank(alice);
            pool.swapExactIn(deficit, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        }
    }

    function _setBidAskWithSpread(uint256 mid, uint256 spreadBps) internal {
        uint256 delta = (mid * spreadBps) / (2 * BPS);
        uint256 bid = mid > delta ? mid - delta : 1;
        uint256 ask = mid + delta;
        updateSpot(mid, 0, true);
        updateBidAsk(bid, ask, spreadBps, true);
        updatePyth(mid, BASE, 0, 0, 20, 20);
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

    function _writeSpreadSeriesCSV(string memory path, uint256[] memory x, uint256[] memory y) internal {
        string memory rows = "step,value\n";
        for (uint256 i = 0; i < x.length; ++i) {
            rows = string(abi.encodePacked(rows, _u(x[i]), ",", _u(y[i]), "\n"));
        }
        _writeCSV(path, rows);
    }

    function _writeCSV(string memory path, string memory data) internal {
        string memory command = string.concat(
            "mkdir -p metrics && cat <<'EOF' > ",
            path,
            "\n",
            data,
            "EOF\n"
        );
        string[] memory inputs = new string[](3);
        inputs[0] = "bash";
        inputs[1] = "-lc";
        inputs[2] = command;
        vm.ffi(inputs);
    }

    function _u(uint256 value) internal pure returns (string memory) {
        return vm.toString(value);
    }

    function assertBetween(uint256 actual, uint256 expected, uint256 tolerance, string memory err) internal pure {
        if (actual > expected) {
            require(actual - expected <= tolerance, err);
        } else {
            require(expected - actual <= tolerance, err);
        }
    }
}
