// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Vm.sol";
import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {FixedPointMath} from "../../contracts/lib/FixedPointMath.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract PreviewParityTest is BaseTest {
    function setUp() public {
        setUpBase();
        approveAll(alice);
        enableBlend();
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
        updateBidAsk(newMid, newMid, 60, true);
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

        uint256 swapBid = FixedPointMath.mulDivDown(swapEvt.mid, BPS - swapEvt.feeBps, BPS);
        uint256 swapAsk = FixedPointMath.mulDivUp(swapEvt.mid, BPS + swapEvt.feeBps, BPS);
        assertEq(bidPx, swapBid, "tob vs swap bid");
        assertEq(askPx, swapAsk, "tob vs swap ask");
    }
}
