// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";
import {MockCurveDEX} from "../utils/Mocks.sol";

contract ScenarioRepriceUpDownTest is BaseTest {
    MockCurveDEX internal dex;

    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);
        approveAll(carol);

        dex = new MockCurveDEX(address(hype), address(usdc));
        hype.approve(address(dex), type(uint256).max);
        usdc.approve(address(dex), type(uint256).max);
        dex.seed(100_000 ether, 10_000_000000);
    }

    function _rebalanceInventory(address quoteActor, address baseActor) internal {
        (uint128 baseRes, ) = pool.reserves();
        (uint128 targetBase,,) = pool.inventoryConfig();
        (, , , , uint256 baseScale, uint256 quoteScale) = pool.tokenConfig();
        uint256 minBaseTrade = baseScale;
        uint256 minQuoteTrade = quoteScale;

        if (baseRes > targetBase) {
            uint256 delta = uint256(baseRes) - targetBase;
            for (uint256 i = 0; i < 4 && delta > minBaseTrade; ++i) {
                uint256 quoteAmount = _baseToQuote(delta, baseScale, quoteScale);
                if (quoteAmount < minQuoteTrade) quoteAmount = minQuoteTrade;
                deal(address(usdc), quoteActor, quoteAmount);
                approveAll(quoteActor);
                vm.prank(quoteActor);
                pool.swapExactIn(quoteAmount, 0, false, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
                (baseRes,) = pool.reserves();
                if (baseRes <= targetBase) break;
                delta = uint256(baseRes) - targetBase;
            }
        } else if (baseRes < targetBase) {
            uint256 delta = uint256(targetBase) - baseRes;
            for (uint256 i = 0; i < 4 && delta > minBaseTrade; ++i) {
                uint256 baseAmount = delta;
                if (baseAmount < minBaseTrade) baseAmount = minBaseTrade;
                deal(address(hype), baseActor, baseAmount);
                approveAll(baseActor);
                vm.prank(baseActor);
                pool.swapExactIn(baseAmount, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
                (baseRes,) = pool.reserves();
                if (baseRes >= targetBase) break;
                delta = uint256(targetBase) - baseRes;
            }
        }
    }

    function test_reprice_up_then_down() public {
        (, , uint8 baseDecimals, uint8 quoteDecimals,,) = pool.tokenConfig();
        uint256 tradeSize = 20_000 ether;

        // Upward jump
        updateSpot(11e17, 0, true);
        updateBidAsk(108e16, 112e16, 400, true);
        updatePyth(11e17, 1e18, 0, 0, 20, 20);

        DnmPool.QuoteResult memory dnmmQuote = quote(tradeSize, true, IDnmPool.OracleMode.Spot);
        (uint16 baseFee,,,,,,) = pool.feeConfig();
        assertGt(dnmmQuote.feeBpsUsed, baseFee, "fee spikes");

        recordLogs();
        vm.prank(alice);
        pool.swapExactIn(tradeSize, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        EventRecorder.SwapEvent[] memory swapsUp = drainLogsToSwapEvents();
        assertTrue(swapsUp[0].feeBps > baseFee, "event fee high");

        EventRecorder.RejectionCounts memory rejectsUp = EventRecorder.countRejections(swapsUp);
        require(rejectsUp.floor == 0, "no floor breach on up leg");

        EventRecorder.VWAPMetrics memory metricsUp = EventRecorder.computeVWAPMetrics(
            swapsUp,
            baseDecimals,
            quoteDecimals
        );
        uint256 dexQuote = dex.quoteBaseIn(tradeSize);
        uint256 dexVwapUp = _priceBaseIn(tradeSize, dexQuote, baseDecimals, quoteDecimals);
        require(metricsUp.executedVwap >= dexVwapUp, "dnmm should beat cpamm on spike");

        rollBlocks(15);
        vm.warp(block.timestamp + 15);
        updateBidAsk(10998e14, 11002e14, 4, true);
        _rebalanceInventory(carol, alice);
        updateBidAsk(10998e14, 11002e14, 4, true);
        DnmPool.QuoteResult memory cooled = quote(tradeSize, true, IDnmPool.OracleMode.Spot);
        assertLt(cooled.feeBpsUsed, dnmmQuote.feeBpsUsed, "fee decayed");

        // Downward jump
        updateSpot(9e17, 0, true);
        updateBidAsk(88e16, 92e16, 400, true);
        updatePyth(9e17, 1e18, 0, 0, 20, 20);

        uint256 quoteTrade = 5_000_000000;
        DnmPool.QuoteResult memory dnmmQuoteDown = quote(quoteTrade, false, IDnmPool.OracleMode.Spot);
        assertGt(dnmmQuoteDown.feeBpsUsed, baseFee, "fee spikes down move");

        recordLogs();
        deal(address(usdc), bob, quoteTrade);
        approveAll(bob);
        vm.prank(bob);
        pool.swapExactIn(quoteTrade, 0, false, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        EventRecorder.SwapEvent[] memory swapsDown = drainLogsToSwapEvents();
        assertTrue(swapsDown[0].feeBps > baseFee, "fee high on drop");

        EventRecorder.RejectionCounts memory rejectsDown = EventRecorder.countRejections(swapsDown);
        require(rejectsDown.floor == 0, "no floor breach on down leg");

        EventRecorder.VWAPMetrics memory metricsDown = EventRecorder.computeVWAPMetrics(
            swapsDown,
            baseDecimals,
            quoteDecimals
        );
        uint256 dexQuoteDown = dex.quoteQuoteIn(quoteTrade);
        uint256 dexVwapDown = _priceQuoteIn(quoteTrade, dexQuoteDown, baseDecimals, quoteDecimals);
        require(metricsDown.executedVwap <= dexVwapDown, "dnmm better bid buying base");

        rollBlocks(15);
        vm.warp(block.timestamp + 15);
        updateBidAsk(8998e14, 9002e14, 4, true);
        _rebalanceInventory(alice, carol);
        updateBidAsk(8998e14, 9002e14, 4, true);
        DnmPool.QuoteResult memory cooledDown = quote(quoteTrade, false, IDnmPool.OracleMode.Spot);
        assertLt(cooledDown.feeBpsUsed, dnmmQuoteDown.feeBpsUsed, "fee decayed after drop");

        string[] memory rows = new string[](2);
        rows[0] = _formatPhaseRow("up", metricsUp, dexVwapUp);
        rows[1] = _formatPhaseRow("down", metricsDown, dexVwapDown);
        EventRecorder.writeCSV(
            vm,
            "metrics/reprice_up_down.csv",
            "phase,dnmm_vwap,dnmm_mid_vwap,diff_bps,dex_vwap,total_base_e18,total_quote_e18",
            rows
        );

        string memory json = string.concat(
            "{\"up\":{",
            "\"dnmm_vwap\":",
            EventRecorder.uintToString(metricsUp.executedVwap),
            ",\"mid_vwap\":",
            EventRecorder.uintToString(metricsUp.midVwap),
            ",\"diff_bps\":",
            EventRecorder.intToString(metricsUp.diffBps),
            ",\"dex_vwap\":",
            EventRecorder.uintToString(dexVwapUp),
            ",\"base_volume\":",
            EventRecorder.uintToString(metricsUp.totalBaseVolume),
            ",\"quote_volume\":",
            EventRecorder.uintToString(metricsUp.totalQuoteVolume),
            "},\"down\":{\"dnmm_vwap\":",
            EventRecorder.uintToString(metricsDown.executedVwap),
            ",\"mid_vwap\":",
            EventRecorder.uintToString(metricsDown.midVwap),
            ",\"diff_bps\":",
            EventRecorder.intToString(metricsDown.diffBps),
            ",\"dex_vwap\":",
            EventRecorder.uintToString(dexVwapDown),
            ",\"base_volume\":",
            EventRecorder.uintToString(metricsDown.totalBaseVolume),
            ",\"quote_volume\":",
            EventRecorder.uintToString(metricsDown.totalQuoteVolume),
            "}}"
        );

        EventRecorder.writeJSON(vm, "metrics/reprice_up_down.json", json);
    }

    function _baseToQuote(uint256 baseAmount, uint256 baseScale, uint256 quoteScale)
        internal
        pure
        returns (uint256)
    {
        return (baseAmount * quoteScale) / baseScale;
    }

    function _priceBaseIn(
        uint256 baseAmount,
        uint256 quoteAmount,
        uint8 baseDecimals,
        uint8 quoteDecimals
    ) internal pure returns (uint256) {
        if (baseAmount == 0 || quoteAmount == 0) return 0;
        uint256 baseScale = 10 ** baseDecimals;
        uint256 quoteScale = 10 ** quoteDecimals;
        uint256 baseE18 = (baseAmount * 1e18) / baseScale;
        uint256 quoteE18 = (quoteAmount * 1e18) / quoteScale;
        if (baseE18 == 0) return 0;
        return (quoteE18 * 1e18) / baseE18;
    }

    function _priceQuoteIn(
        uint256 quoteAmount,
        uint256 baseAmount,
        uint8 baseDecimals,
        uint8 quoteDecimals
    ) internal pure returns (uint256) {
        if (baseAmount == 0 || quoteAmount == 0) return 0;
        uint256 baseScale = 10 ** baseDecimals;
        uint256 quoteScale = 10 ** quoteDecimals;
        uint256 baseE18 = (baseAmount * 1e18) / baseScale;
        uint256 quoteE18 = (quoteAmount * 1e18) / quoteScale;
        if (baseE18 == 0) return 0;
        return (quoteE18 * 1e18) / baseE18;
    }

    function _formatPhaseRow(
        string memory label,
        EventRecorder.VWAPMetrics memory metrics,
        uint256 dexVwap
    ) internal pure returns (string memory) {
        return string.concat(
            label,
            ",",
            EventRecorder.uintToString(metrics.executedVwap),
            ",",
            EventRecorder.uintToString(metrics.midVwap),
            ",",
            EventRecorder.intToString(metrics.diffBps),
            ",",
            EventRecorder.uintToString(dexVwap),
            ",",
            EventRecorder.uintToString(metrics.totalBaseVolume),
            ",",
            EventRecorder.uintToString(metrics.totalQuoteVolume)
        );
    }
}
