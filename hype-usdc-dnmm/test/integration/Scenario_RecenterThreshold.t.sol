// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract ScenarioRecenterThresholdTest is BaseTest {
    function setUp() public {
        setUpBase();
        approveAll(alice);
    }

    function test_recenter_reduces_inventory_fee() public {
        // skew inventory by adding base
        hype.transfer(address(pool), 20_000 ether);
        pool.sync();

        DnmPool.QuoteResult memory beforeQuote = quote(10_000 ether, true, IDnmPool.OracleMode.Spot);
        uint256 feeBefore = beforeQuote.feeBpsUsed;
        (uint16 baseFee,,,,,,) = pool.feeConfig();
        assertGt(feeBefore, baseFee, "inventory term active");

        vm.prank(alice);
        pool.swapExactIn(100 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        (uint128 targetBase,, uint16 recenterPct) = pool.inventoryConfig();
        uint128 delta = (targetBase * (recenterPct + 500)) / 10_000; // push beyond threshold
        uint128 newTarget = targetBase + delta;

        vm.prank(gov);
        pool.setTargetBaseXstar(newTarget);

        DnmPool.QuoteResult memory afterQuote = quote(10_000 ether, true, IDnmPool.OracleMode.Spot);
        assertLt(afterQuote.feeBpsUsed, feeBefore, "fee lowered after recenter");
    }
}
