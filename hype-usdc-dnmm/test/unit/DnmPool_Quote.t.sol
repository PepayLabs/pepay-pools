// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {IOracleAdapterPyth} from "../../contracts/interfaces/IOracleAdapterPyth.sol";
import {BaseTest} from "../utils/BaseTest.sol";

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
}
