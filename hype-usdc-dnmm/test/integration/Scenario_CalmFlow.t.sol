// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";

contract ScenarioCalmFlowTest is BaseTest {
    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);
    }

    function test_calm_flow_sequence() public {
        recordLogs();

        vm.startPrank(alice);
        pool.swapExactIn(200 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        pool.swapExactIn(100 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        vm.stopPrank();

        vm.startPrank(bob);
        pool.swapExactIn(250_000000, 0, false, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        pool.swapExactIn(150_000000, 0, false, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        vm.stopPrank();

        EventRecorder.SwapEvent[] memory swaps = drainLogsToSwapEvents();
        assertEq(swaps.length, 4, "expected swaps");
        (uint16 baseFee,,,,,,) = pool.feeConfig();
        for (uint256 i = 0; i < swaps.length; ++i) {
            // calm conditions keep fee near base
            assertApproxRelBps(swaps[i].feeBps, baseFee, 20, "fee near base");
            assertFalse(swaps[i].isPartial, "no partial fills");
            assertEq(swaps[i].reason, bytes32(0), "no fallback reason");
        }

        DnmPool.QuoteResult memory quoteAfter = quote(50_000000, false, IDnmPool.OracleMode.Spot);
        assertApproxRelBps(quoteAfter.feeBpsUsed, baseFee, 20, "decayed to base");
    }
}
