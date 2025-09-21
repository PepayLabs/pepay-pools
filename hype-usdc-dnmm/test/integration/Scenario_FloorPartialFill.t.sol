// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {Inventory} from "../../contracts/lib/Inventory.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";

contract ScenarioFloorPartialFillTest is BaseTest {
    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);
    }

    function test_partial_fill_hits_floor_both_sides() public {
        (, uint128 quoteBefore) = pool.reserves();
        (, uint16 floorBps,) = pool.inventoryConfig();
        uint256 expectedQuoteFloor = Inventory.floorAmount(uint256(quoteBefore), floorBps);

        recordLogs();
        vm.prank(alice);
        pool.swapExactIn(500_000 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        EventRecorder.SwapEvent[] memory swaps = drainLogsToSwapEvents();
        assertTrue(swaps[0].isPartial, "partial base in");
        assertEq(swaps[0].reason, bytes32("FLOOR"), "floor reason");

        (, uint128 quoteAfter) = pool.reserves();
        assertEq(uint256(quoteAfter), expectedQuoteFloor, "quote floor");

        // replenish quote reserves to test symmetric direction
        usdc.transfer(address(pool), 5_000_000000);
        pool.sync();

        (uint128 baseBefore,) = pool.reserves();
        uint256 expectedBaseFloor = Inventory.floorAmount(uint256(baseBefore), floorBps);

        recordLogs();
        vm.prank(bob);
        pool.swapExactIn(20_000_000000, 0, false, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        swaps = drainLogsToSwapEvents();
        assertTrue(swaps[0].isPartial, "partial quote in");
        assertEq(swaps[0].reason, bytes32("FLOOR"), "floor reason quote");

        (uint128 baseAfter,) = pool.reserves();
        assertEq(uint256(baseAfter), expectedBaseFloor, "base floor");
    }
}
