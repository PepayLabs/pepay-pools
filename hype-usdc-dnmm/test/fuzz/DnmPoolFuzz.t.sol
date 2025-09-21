// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {Inventory} from "../../contracts/lib/Inventory.sol";

contract DnmPoolFuzzTest is Test {
    Inventory.Tokens internal tokens = Inventory.Tokens({baseScale: 1e18, quoteScale: 1e6});

    function testFuzzPartialDoesNotBreachFloor(uint256 amountIn, uint256 reserves) public {
        amountIn = bound(amountIn, 1e6, 1_000_000 ether);
        reserves = bound(reserves, 10_000e6, 2_000_000e6);

        (uint256 amountOut,,) = Inventory.quoteBaseIn(
            amountIn,
            1e18,
            100,
            reserves,
            300,
            tokens
        );

        uint256 floor = Inventory.floorAmount(reserves, 300);
        assertGe(reserves - amountOut, floor, "breached floor");
    }
}
