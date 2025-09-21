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
        updateBidAsk(99998e14, 100002e14, 4, true);
        (uint16 baseFee,,,,,,) = pool.feeConfig();
        DnmPool.QuoteResult memory preQuote = quote(10 ether, true, IDnmPool.OracleMode.Spot);
        uint256 calmFee = preQuote.feeBpsUsed;
        assertLe(calmFee, baseFee + 20, "calm fee bound");
        recordLogs();

        vm.startPrank(alice);
        pool.swapExactIn(50 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        vm.stopPrank();

        vm.startPrank(bob);
        pool.swapExactIn(50_000000, 0, false, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        vm.stopPrank();

        EventRecorder.SwapEvent[] memory swaps = drainLogsToSwapEvents();
        assertEq(swaps.length, 2, "expected swaps");
        for (uint256 i = 0; i < swaps.length; ++i) {
            assertEq(swaps[i].feeBps, calmFee, "fee stable");
            assertFalse(swaps[i].isPartial, "no partial fills");
            assertEq(swaps[i].reason, bytes32(0), "no fallback reason");
        }

        vm.roll(block.number + 5);
        updateBidAsk(999995e12, 1000005e12, 1, true);
        DnmPool.QuoteResult memory quoteAfter = quote(10_000000, false, IDnmPool.OracleMode.Spot);
        assertLe(quoteAfter.feeBpsUsed, baseFee + 20, "fee returns near base");
    }
}
