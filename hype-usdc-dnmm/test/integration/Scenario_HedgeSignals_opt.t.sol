// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";
import {Vm} from "forge-std/Vm.sol";

contract ScenarioHedgeSignalsOptTest is BaseTest {
    function setUp() public {
        setUpBase();
        approveAll(alice);
    }

    function test_target_base_signal_emits_context() public {
        vm.prank(alice);
        pool.swapExactIn(100 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        (uint128 target,, uint16 recenterPct,,,,) = pool.inventoryConfig();
        uint128 newTarget = target + (target * (recenterPct + 500)) / 10_000;

        vm.recordLogs();
        vm.prank(gov);
        pool.setTargetBaseXstar(newTarget);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == EventRecorder.targetXstarSig()) {
                (uint128 oldTarget, uint128 updatedTarget, uint256 mid, uint64 ts) =
                    abi.decode(logs[i].data, (uint128, uint128, uint256, uint64));
                assertEq(oldTarget, target, "old target");
                assertEq(updatedTarget, newTarget, "new target");
                assertEq(mid, pool.lastMid(), "mid context");
                assertEq(ts, pool.lastMidTimestamp(), "timestamp context");
                return;
            }
        }
        fail("target event not found");
    }
}
