// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract ScenarioTimestampGuardsTest is BaseTest {
    function setUp() public {
        setUpBase();
        approveAll(alice);
        enableBlend();
    }

    function test_backward_timestamp_reverts_invalid_ts() public {
        updateSpot(1e18, 1, true);
        updateBidAsk(995e15, 1_005e15, 20, true);
        updateEma(1e18, 1, true);
        updatePyth(1e18, 1e18, 1, 1, 30, 30);

        swap(alice, 5 ether, 0, true, IDnmPool.OracleMode.Spot, block.timestamp + 5);

        uint256 currentTs = block.timestamp;
        vm.warp(currentTs - 1);
        vm.expectRevert(bytes(Errors.INVALID_TS));
        quote(1 ether, true, IDnmPool.OracleMode.Spot);

        vm.warp(currentTs + 2);
        DnmPool.QuoteResult memory res = quote(1 ether, true, IDnmPool.OracleMode.Spot);
        assertGt(res.amountOut, 0, "quote resumes after forward time");
    }
}
