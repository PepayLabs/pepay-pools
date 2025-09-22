// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {IOracleAdapterPyth} from "../../contracts/interfaces/IOracleAdapterPyth.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";

contract DnmPoolQuoteTest is BaseTest {
    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);
    }

    function test_quote_symmetry_base_in_and_quote_in() public {
        DnmPool.QuoteResult memory baseQuote = quote(1_000 ether, true, IDnmPool.OracleMode.Spot);
        DnmPool.QuoteResult memory quoteQuote = quote(1_000_000000, false, IDnmPool.OracleMode.Spot);
        assertGt(baseQuote.amountOut, 0, "base out");
        assertGt(quoteQuote.amountOut, 0, "quote out");

        uint256 impliedMidFromBase = (baseQuote.amountOut * 1e18) / 1_000 ether;
        uint256 impliedMidFromQuote = (1_000_000000 * 1e18) / quoteQuote.amountOut;
        assertApproxRelBps(impliedMidFromBase, impliedMidFromQuote, 500, "mid symmetry");
    }

    function test_quote_uses_mid_and_fee_components() public {
        // widen spread to raise confidence component
        updateBidAsk(95e16, 105e16, 1000, true);
        // skew inventory by adding extra base liquidity
        hype.transfer(address(pool), 40_000 ether);
        pool.sync();

        DnmPool.QuoteResult memory res = quote(5_000 ether, true, IDnmPool.OracleMode.Spot);
        (uint16 baseBps,,,,,,) = pool.feeConfig();
        assertTrue(res.feeBpsUsed > baseBps, "fee includes signals");
        assertEq(res.midUsed, 1e18, "mid original");
        assertTrue(res.usedFallback, "ema fallback used");
    }

    function test_quote_rejects_when_gates_fail() public {
        updateSpot(1e18, 1_000, true); // stale vs maxAge 60
        updateEma(0, 0, false);
        IOracleAdapterPyth.PythResult memory py;
        py.success = false;
        oraclePyth.setResult(py);

        vm.expectRevert(bytes(Errors.ORACLE_STALE));
        quote(100 ether, true, IDnmPool.OracleMode.Spot);
    }

    function test_pyth_fallback_enforces_strict_cap() public {
        DnmPool.OracleConfig memory cfg = defaultOracleConfig();
        updateSpot(1e18, cfg.maxAgeSec + 10, true);
        updateEma(0, 0, false);
        updateBidAsk(0, 0, 0, false);

        IOracleAdapterPyth.PythResult memory res;
        res.hypeUsd = 1_020_000000000000000000;
        res.usdcUsd = 1e18;
        res.ageSecHype = 1;
        res.ageSecUsdc = 1;
        res.confBpsHype = 500;
        res.confBpsUsdc = 500;
        res.success = true;
        oraclePyth.setResult(res);

        vm.recordLogs();
        DnmPool.QuoteResult memory qr = quote(500_000000, false, IDnmPool.OracleMode.Spot);
        assertEq(qr.reason, bytes32("PYTH"), "pyth fallback reason");
        assertTrue(qr.usedFallback, "pyth fallback flagged");

        EventRecorder.ConfidenceDebugEvent[] memory conf =
            EventRecorder.decodeConfidenceDebug(vm.getRecordedLogs());
        assertEq(conf.length, 1, "confidence debug");
        uint256 strictCap = cfg.confCapBpsStrict;
        assertLe(conf[0].confBlendedBps, strictCap, "blend respects strict cap");
        assertLe(conf[0].confPythBps, strictCap, "pyth component capped");
    }

    function test_ema_fallback_precedes_pyth_when_fresh() public {
        DnmPool.OracleConfig memory cfg = defaultOracleConfig();
        updateSpot(1e18, cfg.maxAgeSec + 5, true);
        updateEma(1_005e15, cfg.stallWindowSec - 1, true);
        updateBidAsk(9995e14, 10005e14, 40, true);

        IOracleAdapterPyth.PythResult memory res;
        res.hypeUsd = 1_030_000000000000000000;
        res.usdcUsd = 1e18;
        res.ageSecHype = 1;
        res.ageSecUsdc = 1;
        res.confBpsHype = 400;
        res.confBpsUsdc = 400;
        res.success = true;
        oraclePyth.setResult(res);

        vm.recordLogs();
        DnmPool.QuoteResult memory qr = quote(5_000 ether, true, IDnmPool.OracleMode.Spot);
        assertEq(qr.reason, bytes32("EMA"), "ema fallback reason");
        assertTrue(qr.usedFallback, "ema fallback flagged");

        EventRecorder.ConfidenceDebugEvent[] memory conf =
            EventRecorder.decodeConfidenceDebug(vm.getRecordedLogs());
        assertEq(conf.length, 1, "confidence debug");
        assertEq(conf[0].confPythBps, 0, "pyth component suppressed when EMA wins");
    }
}
