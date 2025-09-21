// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";
import {MockCurveDEX} from "../utils/Mocks.sol";

contract ScenarioRepriceUpDownTest is BaseTest {
    MockCurveDEX internal dex;

    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);

        dex = new MockCurveDEX(address(hype), address(usdc));
        hype.approve(address(dex), type(uint256).max);
        usdc.approve(address(dex), type(uint256).max);
        dex.seed(100_000 ether, 10_000_000000);
    }

    function test_reprice_up_then_down() public {
        uint256 tradeSize = 20_000 ether;

        // Upward jump
        updateSpot(11e17, 0, true);
        updateBidAsk(108e16, 112e16, 400, true);

        DnmPool.QuoteResult memory dnmmQuote = quote(tradeSize, true, IDnmPool.OracleMode.Spot);
        uint256 cpammQuote = dex.quoteBaseIn(tradeSize);
        (uint16 baseFee,,,,,,) = pool.feeConfig();
        assertGt(dnmmQuote.feeBpsUsed, baseFee, "fee spikes");
        assertGt(dnmmQuote.amountOut, cpammQuote, "dnmm better than cpamm");

        recordLogs();
        vm.prank(alice);
        pool.swapExactIn(tradeSize, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        EventRecorder.SwapEvent[] memory swaps = drainLogsToSwapEvents();
        assertTrue(swaps[0].feeBps > baseFee, "event fee high");

        rollBlocks(15);
        DnmPool.QuoteResult memory cooled = quote(tradeSize, true, IDnmPool.OracleMode.Spot);
        assertLt(cooled.feeBpsUsed, dnmmQuote.feeBpsUsed, "fee decayed");

        // Downward jump
        updateSpot(9e17, 0, true);
        updateBidAsk(88e16, 92e16, 400, true);

        uint256 quoteTrade = 5_000_000000;
        DnmPool.QuoteResult memory dnmmQuoteDown = quote(quoteTrade, false, IDnmPool.OracleMode.Spot);
        uint256 cpammQuoteDown = dex.quoteQuoteIn(quoteTrade);
        assertGt(dnmmQuoteDown.feeBpsUsed, baseFee, "fee spikes down move");
        assertGt(dnmmQuoteDown.amountOut, cpammQuoteDown, "dnmm better after drop");

        recordLogs();
        vm.prank(bob);
        pool.swapExactIn(tradeSize / 2, 0, false, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        swaps = drainLogsToSwapEvents();
        assertTrue(swaps[0].feeBps > baseFee, "fee high on drop");
    }
}
