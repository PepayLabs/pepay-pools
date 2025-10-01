// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {QuoteRFQ} from "../../contracts/quotes/QuoteRFQ.sol";
import {IQuoteRFQ} from "../../contracts/interfaces/IQuoteRFQ.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";
import {MockCurveDEX} from "../utils/Mocks.sol";
import {Inventory} from "../../contracts/lib/Inventory.sol";

contract ScenarioRFQAggregatorSplitTest is BaseTest {
    QuoteRFQ internal rfq;
    MockCurveDEX internal dex;
    uint256 internal makerKey = 0xABC123;

    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);
        approveAll(carol);

        hype.transfer(alice, 20_000 ether);

        rfq = new QuoteRFQ(address(pool), vm.addr(makerKey));
        dex = new MockCurveDEX(address(hype), address(usdc));
        hype.approve(address(dex), type(uint256).max);
        usdc.approve(address(dex), type(uint256).max);
        dex.seed(100_000 ether, 100_000_000000);

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.blendOn = true;
        flags.debugEmit = true;
        setFeatureFlags(flags);

        vm.prank(alice);
        hype.approve(address(dex), type(uint256).max);

        vm.prank(alice);
        hype.approve(address(rfq), type(uint256).max);
    }

    function _rebalanceInventory(address quoteActor, address baseActor) internal {
        (uint128 baseRes,) = pool.reserves();
        (uint128 targetBase,,) = pool.inventoryConfig();
        (,,,, uint256 baseScale, uint256 quoteScale) = pool.tokenConfig();
        uint256 minBaseTrade = baseScale;
        uint256 minQuoteTrade = quoteScale;

        if (baseRes > targetBase) {
            uint256 delta = uint256(baseRes) - targetBase;
            for (uint256 i = 0; i < 4 && delta > minBaseTrade; ++i) {
                uint256 quoteAmount = (delta * quoteScale) / baseScale;
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

        (baseRes,) = pool.reserves();
        emit log_named_uint("post_rebalance_base", baseRes);
        emit log_named_uint("target_base", targetBase);
        (uint128 baseFinal, uint128 quoteFinal) = pool.reserves();
        Inventory.Tokens memory tokens = Inventory.Tokens({baseScale: baseScale, quoteScale: quoteScale});
        uint256 invDev = Inventory.deviationBps(baseFinal, quoteFinal, targetBase, pool.lastMid(), tokens);
        emit log_named_uint("post_rebalance_inv_dev", invDev);
    }

    function test_aggregator_prefers_dnmm_post_reprice() public {
        (,, uint8 baseDecimals, uint8 quoteDecimals,,) = pool.tokenConfig();
        updateSpot(11e17, 0, true);
        updateBidAsk(108e16, 112e16, 400, true);
        updatePyth(11e17, 1e18, 0, 0, 20, 20);

        uint256 orderSize = 8_000 ether;
        DnmPool.QuoteResult memory poolQuote = quote(orderSize, true, IDnmPool.OracleMode.Spot);
        uint256 dexQuote = dex.quoteBaseIn(orderSize);
        uint16 baseFee = defaultFeeConfig().baseBps;
        assertGt(poolQuote.feeBpsUsed, baseFee, "fee spike");
        assertGt(poolQuote.amountOut, dexQuote, "dnmm better than cpamm");

        IQuoteRFQ.QuoteParams memory params = IQuoteRFQ.QuoteParams({
            taker: alice,
            amountIn: orderSize * 3 / 4,
            minAmountOut: 0,
            isBaseIn: true,
            expiry: block.timestamp + 60,
            salt: 77
        });
        bytes memory sig = _sign(params);

        recordLogs();
        vm.prank(alice);
        uint256 poolOut = rfq.verifyAndSwap(sig, params, bytes(""));

        vm.prank(alice);
        uint256 dexOut = dex.swapBaseIn(orderSize / 4, 0, alice);

        assertGt(poolOut * 4 / 3, dexOut, "pool leg dominates");

        EventRecorder.SwapEvent[] memory swaps = drainLogsToSwapEvents();
        EventRecorder.RejectionCounts memory rejects = EventRecorder.countRejections(swaps);
        require(rejects.floor == 0, "rfq leg should not floor out");

        EventRecorder.VWAPMetrics memory dnmmMetrics =
            EventRecorder.computeVWAPMetrics(swaps, baseDecimals, quoteDecimals);
        uint256 dexLegVwap = _priceBaseIn(orderSize / 4, dexOut, baseDecimals, quoteDecimals);
        uint256 dnmmLegVwap = dnmmMetrics.executedVwap;

        uint256 aggBase = params.amountIn + (orderSize / 4);
        uint256 aggQuote = poolOut + dexOut;
        uint256 aggVwap = _priceBaseIn(aggBase, aggQuote, baseDecimals, quoteDecimals);
        uint256 cpammFull = dex.quoteBaseIn(orderSize);
        uint256 cpammVwap = _priceBaseIn(orderSize, cpammFull, baseDecimals, quoteDecimals);
        require(aggVwap >= cpammVwap, "aggregator vwap must beat pure cpamm");
        emit log_named_uint("poolQuote_fee", poolQuote.feeBpsUsed);

        string[] memory rows = new string[](1);
        rows[0] = _formatRow(
            dnmmLegVwap,
            dnmmMetrics.midVwap,
            dnmmMetrics.diffBps,
            dexLegVwap,
            aggVwap,
            cpammVwap,
            dnmmMetrics.totalBaseVolume,
            dnmmMetrics.totalQuoteVolume
        );
        EventRecorder.writeCSV(
            vm,
            "metrics/rfq_aggregator_split.csv",
            "dnmm_vwap,dnmm_mid_vwap,dnmm_diff_bps,dex_vwap,agg_vwap,cpamm_vwap,dnmm_base_e18,dnmm_quote_e18",
            rows
        );

        string memory json = string.concat(
            "{\"dnmm\":{\"vwap\":",
            EventRecorder.uintToString(dnmmLegVwap),
            ",\"mid_vwap\":",
            EventRecorder.uintToString(dnmmMetrics.midVwap),
            ",\"diff_bps\":",
            EventRecorder.intToString(dnmmMetrics.diffBps),
            ",\"base_volume\":",
            EventRecorder.uintToString(dnmmMetrics.totalBaseVolume),
            ",\"quote_volume\":",
            EventRecorder.uintToString(dnmmMetrics.totalQuoteVolume),
            "},\"dex_leg_vwap\":",
            EventRecorder.uintToString(dexLegVwap),
            ",\"aggregated_vwap\":",
            EventRecorder.uintToString(aggVwap),
            ",\"cpamm_vwap\":",
            EventRecorder.uintToString(cpammVwap),
            "}"
        );
        EventRecorder.writeJSON(vm, "metrics/rfq_aggregator_split.json", json);

        rollBlocks(20);
        vm.warp(block.timestamp + 20);
        updateBidAsk(10998e14, 11002e14, 4, true);
        updatePyth(10998e14, 1e18, 0, 0, 20, 20);
        _rebalanceInventory(carol, alice);
        updateBidAsk(10998e14, 11002e14, 4, true);
        rollBlocks(1);
        vm.warp(block.timestamp + 1);
        vm.recordLogs();
        DnmPool.QuoteResult memory calmQuote = quote(orderSize, true, IDnmPool.OracleMode.Spot);
        emit log_named_uint("calmQuote_fee", calmQuote.feeBpsUsed);
        EventRecorder.ConfidenceDebugEvent[] memory calmDebug = EventRecorder.decodeConfidenceDebug(vm.getRecordedLogs());
        if (calmDebug.length > 0) {
            emit log_named_uint("calm_conf", calmDebug[0].confBlendedBps);
            emit log_named_uint("calm_feeBase", calmDebug[0].feeBaseBps);
            emit log_named_uint("calm_feeVol", calmDebug[0].feeVolBps);
            emit log_named_uint("calm_feeInv", calmDebug[0].feeInvBps);
        }
        assertLt(calmQuote.feeBpsUsed, poolQuote.feeBpsUsed, "fee decays");
        assertLe(calmQuote.feeBpsUsed, poolQuote.feeBpsUsed, "fee remained controlled");
    }

    function _priceBaseIn(uint256 baseAmount, uint256 quoteAmount, uint8 baseDecimals, uint8 quoteDecimals)
        internal
        pure
        returns (uint256)
    {
        if (baseAmount == 0 || quoteAmount == 0) return 0;
        uint256 baseScale = 10 ** baseDecimals;
        uint256 quoteScale = 10 ** quoteDecimals;
        uint256 baseE18 = (baseAmount * 1e18) / baseScale;
        uint256 quoteE18 = (quoteAmount * 1e18) / quoteScale;
        if (baseE18 == 0) return 0;
        return (quoteE18 * 1e18) / baseE18;
    }

    function _formatRow(
        uint256 dnmmVwap,
        uint256 midVwap,
        int256 diffBps,
        uint256 dexVwap,
        uint256 aggVwap,
        uint256 cpammVwap,
        uint256 baseVolume,
        uint256 quoteVolume
    ) internal pure returns (string memory) {
        return string.concat(
            EventRecorder.uintToString(dnmmVwap),
            ",",
            EventRecorder.uintToString(midVwap),
            ",",
            EventRecorder.intToString(diffBps),
            ",",
            EventRecorder.uintToString(dexVwap),
            ",",
            EventRecorder.uintToString(aggVwap),
            ",",
            EventRecorder.uintToString(cpammVwap),
            ",",
            EventRecorder.uintToString(baseVolume),
            ",",
            EventRecorder.uintToString(quoteVolume)
        );
    }

    function _sign(IQuoteRFQ.QuoteParams memory params) internal view returns (bytes memory) {
        bytes32 digest = rfq.hashTypedDataV4(params);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
