// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {MockOraclePyth} from "../../contracts/mocks/MockOraclePyth.sol";

contract ScenarioStaleOracleFallbacksTest is BaseTest {
    function setUp() public {
        setUpBase();
        approveAll(alice);
    }

    function test_ema_fallback_used_when_spot_stale() public {
        updateSpot(1e18, 1, true);
        updateBidAsk(90e16, 110e16, 2_000, true);
        updateEma(995e15, 1, true);

        DnmPool.QuoteResult memory res = quote(100 ether, true, IDnmPool.OracleMode.Spot);
        assertTrue(res.usedFallback, "fallback used");
        assertEq(res.reason, bytes32("EMA"), "ema reason");
        assertEq(res.midUsed, 995e15, "ema mid");
    }

    function test_pyth_fallback_when_ema_invalid() public {
        updateSpot(1e18, 600, true);
        updateEma(0, 0, false);
        updatePyth(98e16, 1e18, 1, 1, 50, 40);

        oraclePyth.setForcePeekRevert(true);
        vm.expectRevert(MockOraclePyth.ForcedPeek.selector);
        quote(100 ether, true, IDnmPool.OracleMode.Spot);
        oraclePyth.setForcePeekRevert(false);

        DnmPool.QuoteResult memory res = quote(100 ether, true, IDnmPool.OracleMode.Spot);
        assertTrue(res.usedFallback, "fallback used");
        assertEq(res.reason, bytes32("PYTH"), "pyth reason");
        assertEq(res.midUsed, (98e16 * 1e18) / 1e18, "pyth mid");
    }

    function test_spotModeSkipsPythWhenHealthy() public {
        oraclePyth.setForceReadRevert(true);
        updateSpot(1e18, 2, true);
        updateBidAsk(99e16, 101e16, 200, true);

        DnmPool.QuoteResult memory res = quote(50 ether, true, IDnmPool.OracleMode.Spot);
        assertFalse(res.usedFallback, "no fallback expected");

        oraclePyth.setForceReadRevert(false);
    }

    function test_spotModeRequiresPythWhenFallbackTriggered() public {
        oraclePyth.setForcePeekRevert(true);
        updateSpot(0, 0, false);
        updateEma(0, 0, false);

        vm.expectRevert(MockOraclePyth.ForcedPeek.selector);
        quote(100 ether, true, IDnmPool.OracleMode.Spot);

        oraclePyth.setForcePeekRevert(false);
    }
}
