// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Inventory} from "../../contracts/lib/Inventory.sol";

contract InventoryFloorMonotonic is Test {
    Inventory.Tokens internal tokens;

    function setUp() public {
        tokens = Inventory.Tokens({baseScale: 1e18, quoteScale: 1e6});
    }

    function testFuzz_baseInFloorInvariants(
        uint256 quoteReserves,
        uint16 floorBps,
        uint256 amountIn,
        uint256 mid,
        uint16 feeBps
    ) public view {
        quoteReserves = bound(quoteReserves, 1_000_000, 5_000_000_000_000);
        floorBps = uint16(bound(floorBps, 0, 5_000));
        amountIn = bound(amountIn, 1e9, 50_000_000 ether);
        mid = bound(mid, 1e16, 5e18);
        feeBps = uint16(bound(feeBps, 0, 9_999));

        (uint256 amountOut, uint256 applied, bool isPartial) =
            Inventory.quoteBaseIn(amountIn, mid, feeBps, quoteReserves, floorBps, tokens);

        uint256 floor = Inventory.floorAmount(quoteReserves, floorBps);
        uint256 postReserves = quoteReserves - amountOut;
        assertGe(postReserves, floor, "quote reserves must stay above floor");
        assertLe(amountOut, Inventory.availableInventory(quoteReserves, floorBps), "clamp to available quote");

        if (isPartial) {
            assertLt(applied, amountIn, "partial fill must consume less input");
        } else {
            assertEq(applied, amountIn, "full fill consumes entire input");
        }

        uint256 leftover = amountIn - applied;
        assertEq(applied + leftover, amountIn, "base input conservation");

        uint256 bump = amountIn / 10 + 1;
        if (amountIn > type(uint256).max - bump) bump = type(uint256).max - amountIn;
        uint256 largerAmountIn = amountIn + bump;
        (uint256 amountOutLarger,,) =
            Inventory.quoteBaseIn(largerAmountIn, mid, feeBps, quoteReserves, floorBps, tokens);
        assertGe(amountOutLarger, amountOut, "monotone amountOut");
    }

    function testFuzz_quoteInFloorInvariants(
        uint256 baseReserves,
        uint16 floorBps,
        uint256 amountIn,
        uint256 mid,
        uint16 feeBps
    ) public view {
        baseReserves = bound(baseReserves, 100 ether, 5_000_000 ether);
        floorBps = uint16(bound(floorBps, 0, 5_000));
        amountIn = bound(amountIn, 1_000_000, 5_000_000_000000);
        mid = bound(mid, 1e16, 5e18);
        feeBps = uint16(bound(feeBps, 0, 9_999));

        (uint256 amountOut, uint256 applied, bool isPartial) =
            Inventory.quoteQuoteIn(amountIn, mid, feeBps, baseReserves, floorBps, tokens);

        uint256 floor = Inventory.floorAmount(baseReserves, floorBps);
        uint256 postReserves = baseReserves - amountOut;
        assertGe(postReserves, floor, "base reserves must stay above floor");
        assertLe(amountOut, Inventory.availableInventory(baseReserves, floorBps), "clamp to available base");

        if (isPartial) {
            assertLt(applied, amountIn, "partial fill must consume less quote");
        } else {
            assertEq(applied, amountIn, "full fill consumes entire quote input");
        }

        uint256 leftover = amountIn - applied;
        assertEq(applied + leftover, amountIn, "quote input conservation");

        uint256 bump = amountIn / 10 + 1;
        if (amountIn > type(uint256).max - bump) bump = type(uint256).max - amountIn;
        uint256 largerAmountIn = amountIn + bump;
        (uint256 amountOutLarger,,) =
            Inventory.quoteQuoteIn(largerAmountIn, mid, feeBps, baseReserves, floorBps, tokens);
        assertGe(amountOutLarger, amountOut, "monotone amountOut");
    }
}
