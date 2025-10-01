// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OracleWatcher} from "../../contracts/observer/OracleWatcher.sol";
import {DnmPauseHandler} from "../../contracts/observer/DnmPauseHandler.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract OracleWatcherPauseHandlerIntegrationTest is BaseTest {
    OracleWatcher internal watcher;
    DnmPauseHandler internal handler;

    function setUp() public {
        setUpBase();

        handler = new DnmPauseHandler(pool, gov, 300);
        vm.prank(gov);
        pool.setPauser(address(handler));

        OracleWatcher.Config memory cfg = OracleWatcher.Config({maxAgeCritical: 30, divergenceCriticalBps: 40});
        watcher = new OracleWatcher(pool, cfg, address(handler), true);

        vm.prank(gov);
        handler.setWatcher(address(watcher));
    }

    function test_autoPauseTriggersAndCooldown() public {
        assertFalse(pool.paused(), "initially unpaused");

        updateSpot(1e18, 120, true); // exceed critical age

        watcher.check(bytes32("AGE"), bytes(""));
        assertTrue(pool.paused(), "pool paused via handler");

        vm.prank(gov);
        pool.unpause();

        watcher.check(bytes32("AGE"), bytes(""));
        assertFalse(pool.paused(), "cooldown blocks subsequent pause");

        warpTo(block.timestamp + 301);

        watcher.check(bytes32("AGE"), bytes(""));
        assertTrue(pool.paused(), "pause allowed after cooldown");
    }
}
