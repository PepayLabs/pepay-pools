// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {IQuoteRFQ} from "../../contracts/interfaces/IQuoteRFQ.sol";
import {FixedPointMath} from "../../contracts/lib/FixedPointMath.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {OracleUtils} from "../../contracts/lib/OracleUtils.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {QuoteRFQ} from "../../contracts/quotes/QuoteRFQ.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract PreviewParityTest is BaseTest {
    QuoteRFQ internal rfq;
    uint256 internal makerKey;

    function setUp() public {
        setUpBase();
        approveAll(alice);
        enableBlend();
        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.debugEmit = true;
        setFeatureFlags(flags);

        makerKey = 0xA11CE;
        address makerAddr = vm.addr(makerKey);
        rfq = new QuoteRFQ(address(pool), makerAddr);
        vm.startPrank(alice);
        hype.approve(address(rfq), type(uint256).max);
        usdc.approve(address(rfq), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        hype.approve(address(rfq), type(uint256).max);
        usdc.approve(address(rfq), type(uint256).max);
        vm.stopPrank();
    }

    function test_quote_preview_matches_swap_same_block() public {
        // Warm up state so sigma has a baseline and lastObservedMid is populated.
        updateSpot(1e18, 2, true);
        updateBidAsk(995e15, 1_005e15, 20, true);
        updateEma(1e18, 2, true);
        updatePyth(1e18, 1e18, 1, 1, 20, 20);
        swap(alice, 5 ether, 0, true, IDnmPool.OracleMode.Spot, block.timestamp + 5);

        // Advance time to simulate fresh oracle data.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        uint256 newMid = 1_050_000_000_000_000_000; // 1.05 * 1e18
        updateSpot(newMid, 3, true);
        updateBidAsk(1_046_850_000_000_000_000, 1_053_150_000_000_000_000, 60, true);
        updateEma(newMid - 2e16, 4, true);
        updatePyth(newMid, 1e18, 2, 2, 25, 25);

        (uint128 s0Notional,) = pool.makerConfig();
        (uint256 bidPx, uint256 askPx,,) = pool.getTopOfBookQuote(uint256(s0Notional));

        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        DnmPool.QuoteResult memory preview = quote(20 ether, true, IDnmPool.OracleMode.Spot);
        Vm.Log[] memory previewLogs = vm.getRecordedLogs();
        EventRecorder.ConfidenceDebugEvent[] memory previewDebug = EventRecorder.decodeConfidenceDebug(previewLogs);
        require(previewDebug.length == 1, "preview debug");
        assertEq(previewDebug[0].confPythBps, 0, "preview pyth conf zero");

        uint256 expectedBid = FixedPointMath.mulDivDown(preview.midUsed, BPS - preview.feeBpsUsed, BPS);
        uint256 expectedAsk = FixedPointMath.mulDivUp(preview.midUsed, BPS + preview.feeBpsUsed, BPS);
        assertEq(bidPx, expectedBid, "preview vs tob bid");
        assertEq(askPx, expectedAsk, "preview vs tob ask");

        vm.revertToState(snapshot);

        vm.recordLogs();
        swap(alice, 20 ether, 0, true, IDnmPool.OracleMode.Spot, block.timestamp + 5);
        Vm.Log[] memory swapLogs = vm.getRecordedLogs();
        EventRecorder.SwapEvent[] memory swaps = EventRecorder.decodeSwapEvents(swapLogs);
        EventRecorder.ConfidenceDebugEvent[] memory swapDebug = EventRecorder.decodeConfidenceDebug(swapLogs);

        require(swaps.length == 1, "swap count");
        require(swapDebug.length == 1, "swap debug");

        EventRecorder.SwapEvent memory swapEvt = swaps[0];
        EventRecorder.ConfidenceDebugEvent memory swapDbg = swapDebug[0];

        assertEq(swapEvt.mid, preview.midUsed, "mid parity");
        assertEq(swapEvt.feeBps, preview.feeBpsUsed, "fee parity");
        assertEq(swapDbg.confBlendedBps, previewDebug[0].confBlendedBps, "conf parity");
        assertEq(swapDbg.sigmaBps, previewDebug[0].sigmaBps, "sigma parity");
        assertEq(swapDbg.confPythBps, 0, "swap pyth conf zero");

        uint256 swapBid = FixedPointMath.mulDivDown(swapEvt.mid, BPS - swapEvt.feeBps, BPS);
        uint256 swapAsk = FixedPointMath.mulDivUp(swapEvt.mid, BPS + swapEvt.feeBps, BPS);
        assertEq(bidPx, swapBid, "tob vs swap bid");
        assertEq(askPx, swapAsk, "tob vs swap ask");
    }

    function test_quote_preview_matches_swap_quote_in_same_block() public {
        updateSpot(1e18, 2, true);
        updateBidAsk(998e15, 1_002e15, 35, true);
        updateEma(1e18, 3, true);
        updatePyth(1e18, 1e18, 1, 1, 30, 30);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        uint256 newMid = 995_000_000_000_000_000; // slight discount
        updateSpot(newMid, 3, true);
        updateBidAsk(991_522_500_000_000_000, 998_477_500_000_000_000, 70, true);
        updateEma(newMid + 2e16, 4, true);
        updatePyth(newMid, 1e18, 2, 2, 40, 40);

        uint256 amountInQuote = 250_000000; // 250 USDC (6 decimals)

        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        DnmPool.QuoteResult memory preview = quote(amountInQuote, false, IDnmPool.OracleMode.Spot);
        Vm.Log[] memory previewLogs = vm.getRecordedLogs();
        EventRecorder.ConfidenceDebugEvent[] memory previewDebug = EventRecorder.decodeConfidenceDebug(previewLogs);
        require(previewDebug.length == 1, "preview debug quote in");
        assertEq(previewDebug[0].confPythBps, 0, "quote preview pyth conf zero");

        vm.revertToState(snapshot);

        vm.recordLogs();
        uint256 swapAmountOut = swap(alice, amountInQuote, 0, false, IDnmPool.OracleMode.Spot, block.timestamp + 5);
        Vm.Log[] memory swapLogs = vm.getRecordedLogs();
        EventRecorder.SwapEvent[] memory swaps = EventRecorder.decodeSwapEvents(swapLogs);
        EventRecorder.ConfidenceDebugEvent[] memory swapDebug = EventRecorder.decodeConfidenceDebug(swapLogs);
        require(swaps.length == 1, "swap count quote in");
        require(swapDebug.length == 1, "swap debug quote in");

        EventRecorder.SwapEvent memory swapEvt = swaps[0];
        EventRecorder.ConfidenceDebugEvent memory swapDbg = swapDebug[0];

        assertEq(swapAmountOut, preview.amountOut, "quote-in amount parity");
        assertEq(swapEvt.amountOut, preview.amountOut, "quote-in event amount parity");
        assertEq(swapEvt.mid, preview.midUsed, "quote-in mid parity");
        assertEq(swapEvt.feeBps, preview.feeBpsUsed, "quote-in fee parity");
        assertEq(swapDbg.confBlendedBps, previewDebug[0].confBlendedBps, "quote-in conf parity");
        assertEq(swapDbg.confPythBps, 0, "quote swap pyth conf zero");
        assertEq(swapEvt.reason, preview.reason, "quote-in reason parity");
        assertEq(swapEvt.isPartial, preview.partialFillAmountIn > 0, "quote-in partial parity");
    }

    function test_rfq_preview_matches_verify_same_block() public {
        updateSpot(1_012_000_000_000_000_000, 2, true);
        updateBidAsk(1_008_000_000_000_000_000, 1_016_000_000_000_000_000, 80, true);
        updateEma(1_011_000_000_000_000_000, 3, true);
        updatePyth(1_012_000_000_000_000_000, 1e18, 2, 2, 45, 45);

        IQuoteRFQ.QuoteParams memory params = IQuoteRFQ.QuoteParams({
            taker: alice,
            amountIn: 30 ether,
            minAmountOut: 0,
            isBaseIn: true,
            expiry: block.timestamp + 30,
            salt: 42
        });
        bytes memory sig = _signQuote(params);

        uint256 snapshot = vm.snapshotState();

        vm.recordLogs();
        DnmPool.QuoteResult memory preview = quote(params.amountIn, params.isBaseIn, IDnmPool.OracleMode.Spot);
        Vm.Log[] memory previewLogs = vm.getRecordedLogs();
        EventRecorder.ConfidenceDebugEvent[] memory previewDebug = EventRecorder.decodeConfidenceDebug(previewLogs);
        require(previewDebug.length == 1, "preview debug rfq");

        vm.revertToState(snapshot);

        vm.recordLogs();
        vm.prank(params.taker);
        uint256 rfqAmountOut = rfq.verifyAndSwap(sig, params, bytes(""));
        Vm.Log[] memory swapLogs = vm.getRecordedLogs();
        EventRecorder.SwapEvent[] memory swaps = EventRecorder.decodeSwapEvents(swapLogs);
        EventRecorder.ConfidenceDebugEvent[] memory swapDebug = EventRecorder.decodeConfidenceDebug(swapLogs);
        require(swaps.length == 1, "swap count rfq");
        require(swapDebug.length == 1, "swap debug rfq");

        EventRecorder.SwapEvent memory swapEvt = swaps[0];
        EventRecorder.ConfidenceDebugEvent memory swapDbg = swapDebug[0];

        assertEq(rfqAmountOut, preview.amountOut, "rfq amount parity");
        assertEq(swapEvt.amountOut, preview.amountOut, "rfq event amount parity");
        assertEq(swapEvt.mid, preview.midUsed, "rfq mid parity");
        assertEq(swapEvt.feeBps, preview.feeBpsUsed, "rfq fee parity");
        assertEq(swapDbg.confBlendedBps, previewDebug[0].confBlendedBps, "rfq conf parity");
        assertEq(swapDbg.confPythBps, previewDebug[0].confPythBps, "rfq pyth parity");
        assertEq(swapDbg.sigmaBps, previewDebug[0].sigmaBps, "rfq sigma parity");
        assertEq(swapDbg.feeTotalBps, preview.feeBpsUsed, "rfq fee total parity");
        assertEq(swapEvt.reason, preview.reason, "rfq reason parity");
        assertEq(swapEvt.isPartial, preview.partialFillAmountIn > 0, "rfq partial parity");
    }

    function test_rfq_blocks_and_resumes_through_divergence_gate() public {
        uint16 divergenceCap = defaultOracleConfig().divergenceBps;

        updateSpot(1_000_000_000_000_000_000, 2, true);
        updateBidAsk(998_000_000_000_000_000, 1_002_000_000_000_000_000, 40, true);
        updateEma(1_000_000_000_000_000_000, 3, true);
        updatePyth(1_120_000_000_000_000_000, 1e18, 2, 2, 40, 40);

        IQuoteRFQ.QuoteParams memory params = IQuoteRFQ.QuoteParams({
            taker: alice,
            amountIn: 18 ether,
            minAmountOut: 0,
            isBaseIn: true,
            expiry: block.timestamp + 120,
            salt: 99
        });
        bytes memory sig = _signQuote(params);

        (uint256 hcMid,,) = oracleHC.spot();
        uint256 expectedDelta = OracleUtils.computeDivergenceBps(hcMid, 1_120_000_000_000_000_000);
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleDiverged.selector, expectedDelta, divergenceCap));
        quote(params.amountIn, params.isBaseIn, IDnmPool.OracleMode.Spot);

        vm.prank(params.taker);
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleDiverged.selector, expectedDelta, divergenceCap));
        rfq.verifyAndSwap(sig, params, bytes(""));

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        uint256 resolvedMid = 1_004_000_000_000_000_000;
        updateSpot(resolvedMid, 1, true);
        updateBidAsk(resolvedMid - 2_000_000_000_000_000, resolvedMid + 2_000_000_000_000_000, 40, true);
        updateEma(resolvedMid, 2, true);
        updatePyth(resolvedMid, 1e18, 2, 2, 35, 35);

        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        DnmPool.QuoteResult memory preview = quote(params.amountIn, params.isBaseIn, IDnmPool.OracleMode.Spot);
        Vm.Log[] memory previewLogs = vm.getRecordedLogs();
        EventRecorder.ConfidenceDebugEvent[] memory previewDebug = EventRecorder.decodeConfidenceDebug(previewLogs);
        require(previewDebug.length == 1, "preview debug recalc");
        require(previewDebug[0].confPythBps == 0, "preview pyth zero");
        require(previewDebug[0].confBlendedBps <= divergenceCap, "preview conf bounded");

        vm.revertToState(snapshot);

        vm.recordLogs();
        vm.prank(params.taker);
        uint256 amountOut = rfq.verifyAndSwap(sig, params, bytes(""));
        Vm.Log[] memory swapLogs = vm.getRecordedLogs();
        EventRecorder.SwapEvent[] memory swaps = EventRecorder.decodeSwapEvents(swapLogs);
        EventRecorder.ConfidenceDebugEvent[] memory swapDebug = EventRecorder.decodeConfidenceDebug(swapLogs);
        require(swaps.length == 1, "rfq swap count");
        require(swapDebug.length == 1, "rfq debug count");

        EventRecorder.SwapEvent memory swapEvt = swaps[0];
        EventRecorder.ConfidenceDebugEvent memory swapDbg = swapDebug[0];

        assertEq(amountOut, preview.amountOut, "rfq resumed amount");
        assertEq(swapEvt.mid, preview.midUsed, "rfq resumed mid");
        assertEq(swapEvt.feeBps, preview.feeBpsUsed, "rfq resumed fee");
        assertEq(swapDbg.confBlendedBps, previewDebug[0].confBlendedBps, "rfq conf match");
        assertEq(swapDbg.confPythBps, previewDebug[0].confPythBps, "rfq pyth match");
    }

    function _signQuote(IQuoteRFQ.QuoteParams memory params) internal view returns (bytes memory) {
        bytes32 digest = rfq.hashTypedDataV4(params);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
