// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {Inventory} from "../../contracts/lib/Inventory.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";

contract ScenarioFloorPartialFillTest is BaseTest {
    function setUp() public {
        setUpBase();
    }

    function _deployCompactPool() internal {
        DnmPool.InventoryConfig memory invCfg = defaultInventoryConfig();
        DnmPool.OracleConfig memory oracleCfg = defaultOracleConfig();
        FeePolicy.FeeConfig memory feeCfg = defaultFeeConfig();
        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();

        redeployPool(invCfg, oracleCfg, feeCfg, makerCfg);
        seedPOL(
            DeployConfig({
                baseLiquidity: 1_000 ether,
                quoteLiquidity: 100_000_000000,
                floorBps: invCfg.floorBps,
                recenterPct: invCfg.recenterThresholdPct,
                divergenceBps: oracleCfg.divergenceBps,
                allowEmaFallback: oracleCfg.allowEmaFallback
            })
        );

        approveAll(alice);
        approveAll(bob);
    }

    function test_partial_fill_base_floor_exact() public {
        _deployCompactPool();
        deal(address(hype), alice, 200_000 ether);
        approveAll(alice);

        (, uint16 floorBps,) = pool.inventoryConfig();
        (, uint128 quoteBefore) = pool.reserves();
        uint256 expectedQuoteFloor = Inventory.floorAmount(uint256(quoteBefore), floorBps);

        recordLogs();
        vm.prank(alice);
        pool.swapExactIn(150_000 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        EventRecorder.SwapEvent[] memory swaps = drainLogsToSwapEvents();
        assertTrue(swaps[0].isPartial, "partial base in");
        assertEq(swaps[0].reason, bytes32("FLOOR"), "floor reason base");

        (, uint128 quoteAfter) = pool.reserves();
        assertEq(uint256(quoteAfter), expectedQuoteFloor, "quote reserves at floor");
    }

    function test_partial_fill_quote_floor_exact() public {
        _deployCompactPool();
        deal(address(usdc), bob, 10_000_000000);
        approveAll(bob);

        (uint128 baseBefore, ) = pool.reserves();
        (, uint16 floorBps, ) = pool.inventoryConfig();
        uint256 expectedBaseFloor = Inventory.floorAmount(uint256(baseBefore), floorBps);

        recordLogs();
        vm.prank(bob);
        pool.swapExactIn(5_000_000000, 0, false, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        EventRecorder.SwapEvent[] memory swaps = drainLogsToSwapEvents();
        assertTrue(swaps[0].isPartial, "partial quote in");
        assertEq(swaps[0].reason, bytes32("FLOOR"), "floor reason quote");

        (uint128 baseAfter, ) = pool.reserves();
        assertEq(uint256(baseAfter), expectedBaseFloor, "base reserves at floor");
    }
}
