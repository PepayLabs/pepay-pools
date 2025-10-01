// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";

contract ScenarioKeeperLatencyTest is BaseTest {
    uint16 internal feeCapBps;

    function setUp() public {
        setUpBase();
        // ensure deterministic oracle config for the test
        DnmPool.OracleConfig memory cfg = defaultOracleConfig();
        cfg.maxAgeSec = 60;
        cfg.stallWindowSec = 15;
        feeCapBps = defaultFeeConfig().capBps;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Oracle, abi.encode(cfg));

        // initial clean state
        updateSpot(1e18, 2, true);
        updateBidAsk(998e15, 1_002e15, 20, true);
        updateEma(1e18, 2, true);
        updatePyth(1e18, 1e18, 0, 0, 20, 20);
    }

    function test_keeper_latency_sequence() public {
        // Fresh read uses spot path
        DnmPool.QuoteResult memory fresh = _quote();
        assertEq(fresh.reason, bytes32(0), "spot path expected");
        assertFalse(fresh.usedFallback, "no fallback");

        // Simulate keeper stall (spot stale but EMA fresh -> fallback to EMA)
        updateSpot(1e18, 120, true); // beyond maxAge
        updateEma(1e18, 5, true);

        DnmPool.QuoteResult memory emaFallback = _quote();
        assertEq(emaFallback.reason, bytes32("EMA"), "EMA fallback");
        assertTrue(emaFallback.usedFallback, "fallback used");
        assertLe(emaFallback.feeBpsUsed, feeCapBps, "fee capped under fallback");

        // Escalate: make EMA stale; rely on Pyth fallback
        updateEma(1e18, 90, true);
        updatePyth(1e18, 1e18, 5, 5, 25, 25);

        DnmPool.QuoteResult memory pythFallback = _quote();
        assertEq(pythFallback.reason, bytes32("PYTH"), "PYTH fallback");
        assertTrue(pythFallback.usedFallback, "pyth used");

        // Recovery: keeper updates spot again -> fallback cleared
        updateSpot(1e18, 3, true);
        updateEma(1e18, 3, true);

        DnmPool.QuoteResult memory recovered = _quote();
        assertEq(recovered.reason, bytes32(0), "recovered to spot");
        assertFalse(recovered.usedFallback, "fallback cleared");
    }

    function _quote() internal returns (DnmPool.QuoteResult memory) {
        return pool.quoteSwapExactIn(5 ether, true, IDnmPool.OracleMode.Spot, bytes(""));
    }
}
