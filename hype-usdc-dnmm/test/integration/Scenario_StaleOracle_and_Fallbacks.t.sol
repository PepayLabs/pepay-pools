// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract ScenarioStaleOracleFallbacksTest is BaseTest {
    function setUp() public {
        setUpBase();
        approveAll(alice);
    }

    function test_ema_fallback_used_when_spot_stale() public {
        updateSpot(1e18, 600, true);
        updateEma(995e15, 10, true);

        DnmPool.QuoteResult memory res = quote(10_000 ether, true, IDnmPool.OracleMode.Spot);
        assertTrue(res.usedFallback, "fallback used");
        assertEq(res.reason, bytes32("EMA"), "ema reason");
        assertEq(res.midUsed, 995e15, "ema mid");
    }

    function test_pyth_fallback_when_ema_invalid() public {
        updateSpot(1e18, 600, true);
        updateEma(0, 0, false);
        updatePyth(98e16, 1e18, 1, 1, 50, 40);

        DnmPool.QuoteResult memory res = quote(10_000 ether, true, IDnmPool.OracleMode.Spot);
        assertTrue(res.usedFallback, "fallback used");
        assertEq(res.reason, bytes32("PYTH"), "pyth reason");
        assertEq(res.midUsed, (98e16 * 1e18) / 1e18, "pyth mid");
    }
}
