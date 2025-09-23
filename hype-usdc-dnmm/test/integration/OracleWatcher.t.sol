// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OracleWatcher} from "../../contracts/observer/OracleWatcher.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract OracleWatcherTest is BaseTest {
    OracleWatcher internal watcher;

    function setUp() public {
        setUpBase();
        OracleWatcher.Config memory cfg = OracleWatcher.Config({
            maxAgeCritical: 40,
            divergenceCriticalBps: 50
        });
        watcher = new OracleWatcher(pool, cfg, address(0), false);
    }

    function test_emits_age_alert_and_returns_state() public {
        updateSpot(1e18, 90, true);
        updateBidAsk(998e15, 1_002e15, 20, true);
        updatePyth(1e18, 1e18, 0, 0, 20, 20);

        vm.expectEmit(true, false, false, true, address(watcher));
        emit OracleWatcher.OracleAlert("AGE", OracleWatcher.AlertKind.Age, 90, 40, true);

        OracleWatcher.CheckResult memory result = watcher.check("AGE", bytes(""));
        assertEq(result.hcAgeSec, 90, "age reflected");
        assertTrue(result.hcSuccess, "hc success");
        assertTrue(result.pythSuccess, "pyth success");
    }

    function test_emits_divergence_alert() public {
        updateSpot(1e18, 5, true);
        updateBidAsk(998e15, 1_002e15, 15, true);
        updatePyth(1_200_000_000_000_000_000, 1e18, 0, 0, 20, 20);

        vm.expectEmit(true, false, false, true, address(watcher));
        emit OracleWatcher.OracleAlert("DELTA", OracleWatcher.AlertKind.Divergence, 2000, 50, true);

        watcher.check("DELTA", bytes(""));
    }

    function test_emits_fallback_alert_when_spread_exceeds_cap() public {
        updateSpot(1e18, 5, true);
        updateBidAsk(900e15, 1_100e15, 300, true); // force spread-driven fallback
        updatePyth(1e18, 1e18, 0, 0, 20, 20);

        vm.expectEmit(true, false, false, true, address(watcher));
        emit OracleWatcher.OracleAlert("FALLBACK", OracleWatcher.AlertKind.Fallback, 300, 80, false);

        OracleWatcher.CheckResult memory result = watcher.check("FALLBACK", bytes(""));
        assertTrue(result.fallbackUsed, "fallback toggled");
    }

    function test_autopause_handler_invoked_on_critical_alert() public {
        MockPauseHandler handler = new MockPauseHandler();
        watcher.setPauseHandler(address(handler));
        watcher.setAutoPauseEnabled(true);

        updateSpot(1e18, 100, true);
        updateBidAsk(998e15, 1_002e15, 15, true);
        updatePyth(1e18, 1e18, 0, 0, 20, 20);

        vm.expectEmit(true, false, false, true, address(watcher));
        emit OracleWatcher.OracleAlert("AUTO", OracleWatcher.AlertKind.Age, 100, 40, true);
        vm.expectEmit(true, false, false, true, address(watcher));
        emit OracleWatcher.AutoPauseRequested("AUTO", true, hex"");

        watcher.check("AUTO", bytes(""));
        assertTrue(handler.invoked(), "handler triggered");
        assertEq(handler.lastLabel(), "AUTO", "label forwarded");
    }
}

contract MockPauseHandler {
    bool internal _invoked;
    bytes32 internal _label;

    function onOracleCritical(bytes32 label) external {
        _invoked = true;
        _label = label;
    }

    function invoked() external view returns (bool) {
        return _invoked;
    }

    function lastLabel() external view returns (bytes32) {
        return _label;
    }
}
