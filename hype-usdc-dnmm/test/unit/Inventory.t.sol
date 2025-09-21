// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {Inventory} from "../../contracts/lib/Inventory.sol";

contract InventoryTest is Test {
    Inventory.Tokens internal tokens;

    function setUp() public {
        tokens = Inventory.Tokens({baseScale: 1e18, quoteScale: 1e6});
    }

    function testPartialBaseInLeavesFloor() public {
        uint256 quoteReserves = 1_000_000e6; // 1M USDC
        uint16 floorBps = 300; // 3%
        (uint256 amountOut, uint256 appliedAmountIn, bool partial) = Inventory.quoteBaseIn(
            1_000 ether,
            1e18,
            100,
            quoteReserves,
            floorBps,
            tokens
        );

        assertTrue(partial, "expected partial fill");
        uint256 expectedAvailable = Inventory.availableInventory(quoteReserves, floorBps);
        assertEq(amountOut, expectedAvailable);
        assertGt(appliedAmountIn, 0);
    }

    function testDeviationZeroWhenBalanced() public {
        uint256 deviation = Inventory.deviationBps(100_000 ether, 100_000e6, 100_000 ether, 1e18, tokens);
        assertEq(deviation, 0);
    }
}
