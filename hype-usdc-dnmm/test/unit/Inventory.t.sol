// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {Inventory} from "../../contracts/lib/Inventory.sol";

contract InventoryTest is Test {
    Inventory.Tokens internal tokens;

    function setUp() public {
        tokens = Inventory.Tokens({baseScale: 1e18, quoteScale: 1e6});
    }

    function test_partialFill_leaves_exact_floor_quote_side() public {
        uint256 quoteReserves = 1_000_000e6;
        uint16 floorBps = 300; // 3%
        uint256 floor = Inventory.floorAmount(quoteReserves, floorBps);
        (uint256 amountOut, uint256 appliedAmountIn, bool isPartial) = Inventory.quoteBaseIn(
            2_000_000 ether,
            1e18,
            100,
            quoteReserves,
            floorBps,
            tokens
        );
        assertTrue(isPartial, "should partial");
        assertGt(appliedAmountIn, 0, "applied amount");
        assertEq(quoteReserves - amountOut, floor, "floor preserved");
    }

    function test_partialFill_leaves_exact_floor_base_side() public {
        uint256 baseReserves = 200_000 ether;
        uint16 floorBps = 300;
        uint256 floor = Inventory.floorAmount(baseReserves, floorBps);
        (uint256 amountOut,, bool isPartial) = Inventory.quoteQuoteIn(20_000_000e6, 1e18, 100, baseReserves, floorBps, tokens);
        assertTrue(isPartial, "should partial");
        assertEq(baseReserves - amountOut, floor, "floor after partial");
    }

    function test_noPartial_when_above_floor() public {
        (uint256 amountOut, uint256 appliedAmountIn, bool isPartial) = Inventory.quoteBaseIn(
            1_000 ether,
            1e18,
            50,
            2_000_000e6,
            300,
            tokens
        );
        assertFalse(isPartial, "no partial");
        assertEq(appliedAmountIn, 1_000 ether, "full amount");
        assertGt(amountOut, 0, "amount out");
    }

    function test_partialFill_rounding_edges() public {
        uint256 quoteReserves = 500_123_456789;
        (uint256 amountOut, uint256 appliedAmountIn, bool isPartial) = Inventory.quoteBaseIn(
            5_000_000 ether,
            997e15,
            75,
            quoteReserves,
            300,
            tokens
        );
        if (isPartial) {
            uint256 floor = Inventory.floorAmount(quoteReserves, 300);
            assertEq(quoteReserves - amountOut, floor, "floor exact");
            assertGt(appliedAmountIn, 0, "non-zero applied");
        }
    }

    function test_fuzz_partial_floor_invariant(uint256 reserves, uint16 floorBps, uint256 amountIn, uint256 mid) public {
        reserves = bound(reserves, 1_000e6, 100_000_000e6);
        floorBps = uint16(bound(floorBps, 0, 5000));
        amountIn = bound(amountIn, 1e6, 5_000_000 ether);
        mid = bound(mid, 1e16, 5e18);

        (uint256 amountOut,,) = Inventory.quoteBaseIn(amountIn, mid, 100, reserves, floorBps, tokens);
        uint256 available = Inventory.availableInventory(reserves, floorBps);
        assertLe(amountOut, available, "never exceed available quote");
    }
}
