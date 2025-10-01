// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {Inventory} from "../../contracts/lib/Inventory.sol";
import {FixedPointMath} from "../../contracts/lib/FixedPointMath.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";

contract ScenarioAomqTest is BaseTest {
    bytes32 private constant REASON_AOMQ = bytes32("AOMQ");
    bytes32 private constant TRIGGER_SOFT = bytes32("SOFT");
    bytes32 private constant TRIGGER_FLOOR = bytes32("FLOOR");

    function setUp() public {
        setUpBase();
    }

    function _configureAomq(uint128 minQuoteNotional, uint16 emergencySpreadBps, uint16 floorEpsilonBps) internal {
        DnmPool.AomqConfig memory cfg = DnmPool.AomqConfig({
            minQuoteNotional: minQuoteNotional,
            emergencySpreadBps: emergencySpreadBps,
            floorEpsilonBps: floorEpsilonBps
        });
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Aomq, abi.encode(cfg));

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.enableAOMQ = true;
        flags.enableSoftDivergence = true;
        flags.enableBboFloor = true;
        setFeatureFlags(flags);
    }

    function test_aomqActivatesOnSoftDivergence() public {
        DnmPool.OracleConfig memory oracleCfg = defaultOracleConfig();
        oracleCfg.allowEmaFallback = false;
        oracleCfg.divergenceBps = 2_000;
        oracleCfg.divergenceAcceptBps = 30;
        oracleCfg.divergenceSoftBps = 60;
        oracleCfg.divergenceHardBps = 2_000;
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Oracle, abi.encode(oracleCfg));

        _configureAomq(50_000000, 120, 100);
        (uint128 minQuote,,) = pool.aomqConfig();
        assertEq(minQuote, 50_000000, "min quote configured");

        updateSpot(1e18, 10, true);
        updateBidAsk(995e15, 1_005e15, 40, true);
        updatePyth(1005e15, 1e18, 0, 0, 0, 0);
        recordLogs();
        DnmPool.QuoteResult memory quoteResult = quote(10_000 ether, true, IDnmPool.OracleMode.Spot);
        EventRecorder.AomqEvent[] memory events = EventRecorder.decodeAomqEvents(vm.getRecordedLogs());

        assertEq(quoteResult.reason, REASON_AOMQ, "reason AOMQ");
        assertGt(quoteResult.partialFillAmountIn, 0, "partial flag");
        assertLt(quoteResult.partialFillAmountIn, 10_000 ether, "clamped");
        assertApproxEqAbs(quoteResult.amountOut, 50_000000, 2, "micro notional");

        assertEq(events.length, 1, "event count");
        assertEq(events[0].trigger, TRIGGER_SOFT, "trigger soft");
        assertTrue(events[0].isBaseIn, "base-in side");
        assertEq(events[0].quoteNotional, quoteResult.amountOut, "event notional");
        assertGe(events[0].spreadBps, 120, "emergency spread floor");
    }

    function test_aomqPartialToFloorExact_noUnderflow() public {
        DnmPool.InventoryConfig memory invCfg = defaultInventoryConfig();
        invCfg.floorBps = 300;
        invCfg.targetBaseXstar = 10_000 ether;
        DnmPool.OracleConfig memory oracleCfg = defaultOracleConfig();
        FeePolicy.FeeConfig memory feeCfg = defaultFeeConfig();
        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();
        makerCfg.s0Notional = 500_000_000000; // 500k quote units reference for ladder sizing

        redeployPool(invCfg, oracleCfg, feeCfg, makerCfg, defaultAomqConfig());
        vm.prank(gov);
        pool.setRecenterCooldownSec(0);
        seedPOL(
            DeployConfig({
                baseLiquidity: 20_000 ether,
                quoteLiquidity: 1_000_000_000000,
                floorBps: invCfg.floorBps,
                recenterPct: invCfg.recenterThresholdPct,
                divergenceBps: oracleCfg.divergenceBps,
                allowEmaFallback: oracleCfg.allowEmaFallback
            })
        );

        approveAll(alice);
        approveAll(bob);

        _configureAomq(80_000000, 90, 600);

        hype.transfer(alice, 1_200_000 ether);
        vm.startPrank(alice);
        pool.swapExactIn(999_800 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        vm.stopPrank();

        (, uint128 quoteReserveBefore) = pool.reserves();
        (, uint16 floorBps,,,,,) = pool.inventoryConfig();
        (uint128 s0Notional,,,) = pool.makerConfig();
        uint256 expectedFloor = Inventory.floorAmount(uint256(quoteReserveBefore), floorBps);
        uint256 availableQuote = Inventory.availableInventory(uint256(quoteReserveBefore), floorBps);
        uint256 slackBps = s0Notional > 0
            ? FixedPointMath.toBps(availableQuote, uint256(s0Notional))
            : 0;
        assertLe(slackBps, 600, "inventory near floor");

        hype.transfer(bob, 50_000 ether);
        approveAll(bob);

        recordLogs();
        vm.prank(bob);
        pool.swapExactIn(40_000 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        EventRecorder.SwapEvent[] memory swaps = EventRecorder.decodeSwapEvents(vm.getRecordedLogs());

        assertEq(swaps.length, 1, "swap event count");
        assertTrue(swaps[0].isPartial, "partial swap");
        assertEq(swaps[0].reason, REASON_AOMQ, "partial reason AOMQ");

        (, uint128 quoteReserveAfter) = pool.reserves();
        assertEq(uint256(quoteReserveAfter), expectedFloor, "floor preserved");
    }

    function test_aomqDoesNotBypassHardFaults() public {
        _configureAomq(30_000000, 80, 100);

        DnmPool.OracleConfig memory oracleCfg = defaultOracleConfig();
        oracleCfg.allowEmaFallback = false;
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Oracle, abi.encode(oracleCfg));

        updateSpot(0, 0, false);
        updateBidAsk(0, 0, 0, false);
        updateEma(0, 0, false);
        updatePyth(0, 0, 0, 0, 0, 0);

        vm.expectRevert(Errors.OracleStale.selector);
        quote(5_000 ether, true, IDnmPool.OracleMode.Spot);
    }

    function test_aomqHonoursBboFloorSpread() public {
        _configureAomq(40_000000, 10, 200);

        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();
        makerCfg.alphaBboBps = 2000; // 20% of spread
        makerCfg.betaFloorBps = 25;
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Maker, abi.encode(makerCfg));

        updateSpot(1e18, 5, true);
        updateBidAsk(998e15, 1_002e15, 400, true);
        updatePyth(1_020e18, 1e18, 0, 0, 0, 0);

        DnmPool.QuoteResult memory result = quote(5_000 ether, true, IDnmPool.OracleMode.Spot);
        assertEq(result.reason, REASON_AOMQ, "AOMQ reason");
        assertGe(result.feeBpsUsed, 25, "fee respects BBO floor");
    }
}
