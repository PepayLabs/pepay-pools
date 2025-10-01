// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {OracleUtils} from "../../contracts/lib/OracleUtils.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract ScenarioPythHygieneTest is BaseTest {
    function setUp() public {
        setUpBase();
        approveAll(alice);
        enableBlend();
        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.debugEmit = true;
        setFeatureFlags(flags);
    }

    function test_confidence_components_zero_pyth_on_hc() public {
        updateSpot(1e18, 2, true);
        updateBidAsk(999e15, 1_001e18, 40, true);
        updateEma(1e18, 3, true);
        updatePyth(1e18, 1e18, 3, 3, 40, 40);

        vm.recordLogs();
        DnmPool.QuoteResult memory res = quote(5 ether, true, IDnmPool.OracleMode.Spot);
        require(!res.usedFallback, "fallback unexpected");

        EventRecorder.ConfidenceDebugEvent[] memory debugs = EventRecorder.decodeConfidenceDebug(vm.getRecordedLogs());
        require(debugs.length == 1, "debug count");
        EventRecorder.ConfidenceDebugEvent memory dbg = debugs[0];
        uint16 capSpot = defaultOracleConfig().confCapBpsSpot;
        require(dbg.confPythBps == 0, "pyth component should be zero");
        require(dbg.confBlendedBps <= capSpot, "spot cap respected");
    }

    function test_pyth_fallback_uses_strict_cap() public {
        DnmPool.OracleConfig memory cfg = defaultOracleConfig();
        uint32 maxAgeSec = cfg.maxAgeSec;
        uint32 stallWindowSec = cfg.stallWindowSec;
        uint16 capStrict = cfg.confCapBpsStrict;
        updateSpot(1_025e15, maxAgeSec + 10, true);
        updateBidAsk(1_020e15, 1_030e15, 45, true);
        updateEma(1_022e15, stallWindowSec + 15, true);
        updatePyth(1_028e15, 1e18, 2, 2, 50, 48);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        vm.recordLogs();
        vm.prank(alice);
        pool.swapExactIn(12 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 5);

        EventRecorder.ConfidenceDebugEvent[] memory debugs = EventRecorder.decodeConfidenceDebug(vm.getRecordedLogs());
        require(debugs.length == 1, "debug count");
        EventRecorder.ConfidenceDebugEvent memory dbg = debugs[0];
        require(dbg.confPythBps > 0, "pyth component missing");
        require(dbg.confPythBps <= capStrict, "strict cap enforced");
        require(dbg.confBlendedBps <= capStrict, "blended respects strict cap");
    }

    function test_divergence_flap_blocks_until_epsilon_resolved() public {
        uint16 divergenceBps = defaultOracleConfig().divergenceBps;
        updateSpot(1e18, 2, true);
        updateBidAsk(995e15, 1_005e15, 25, true);
        updateEma(1e18, 3, true);
        updatePyth(1_120e15, 1e18, 1, 1, 30, 30);

        (uint256 hcMid,,) = oracleHC.spot();
        uint256 expectedDelta = OracleUtils.computeDivergenceBps(hcMid, 1_120e15);
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleDiverged.selector, expectedDelta, divergenceBps));
        quote(10 ether, true, IDnmPool.OracleMode.Spot);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleDiverged.selector, expectedDelta, divergenceBps));
        pool.swapExactIn(10 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 5);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        uint256 healedMid = 1_002_000_000_000_000_000;
        updateSpot(healedMid, 1, true);
        updateBidAsk(healedMid - 1_500_000_000_000_000, healedMid + 1_500_000_000_000_000, 30, true);
        updateEma(healedMid, 2, true);
        updatePyth(healedMid, 1e18, 2, 2, 35, 35);

        vm.recordLogs();
        DnmPool.QuoteResult memory res = quote(10 ether, true, IDnmPool.OracleMode.Spot);
        require(!res.usedFallback, "fallback after recovery");

        EventRecorder.ConfidenceDebugEvent[] memory debugs = EventRecorder.decodeConfidenceDebug(vm.getRecordedLogs());
        require(debugs.length == 1, "debug count");
        require(debugs[0].confPythBps == 0, "pyth zero after recovery");
        require(debugs[0].confBlendedBps <= divergenceBps, "confidence within divergence cap");
    }
}
