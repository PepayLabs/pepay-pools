// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {QuoteRFQ} from "../../contracts/quotes/QuoteRFQ.sol";
import {IQuoteRFQ} from "../../contracts/interfaces/IQuoteRFQ.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {MockCurveDEX} from "../utils/Mocks.sol";

contract ScenarioRFQAggregatorSplitTest is BaseTest {
    QuoteRFQ internal rfq;
    MockCurveDEX internal dex;
    uint256 internal makerKey = 0xABC123;

    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);

        hype.transfer(alice, 20_000 ether);

        rfq = new QuoteRFQ(address(pool), vm.addr(makerKey));
        dex = new MockCurveDEX(address(hype), address(usdc));
        hype.approve(address(dex), type(uint256).max);
        usdc.approve(address(dex), type(uint256).max);
        dex.seed(100_000 ether, 10_000_000000);

        vm.prank(alice);
        hype.approve(address(dex), type(uint256).max);

        vm.prank(alice);
        hype.approve(address(rfq), type(uint256).max);
    }

    function test_aggregator_prefers_dnmm_post_reprice() public {
        updateSpot(11e17, 0, true);
        updateBidAsk(108e16, 112e16, 400, true);

        uint256 orderSize = 30_000 ether;
        DnmPool.QuoteResult memory poolQuote = quote(orderSize, true, IDnmPool.OracleMode.Spot);
        uint256 dexQuote = dex.quoteBaseIn(orderSize);
        (uint16 baseFee,,,,,,) = pool.feeConfig();
        assertGt(poolQuote.feeBpsUsed, baseFee, "fee spike");
        assertGt(poolQuote.amountOut, dexQuote, "dnmm better than cpamm");

        IQuoteRFQ.QuoteParams memory params = IQuoteRFQ.QuoteParams({
            taker: alice,
            amountIn: orderSize * 3 / 4,
            minAmountOut: 0,
            isBaseIn: true,
            expiry: block.timestamp + 60,
            salt: 77
        });
        bytes memory sig = _sign(params);

        vm.prank(alice);
        uint256 poolOut = rfq.verifyAndSwap(sig, params, bytes(""));

        vm.prank(alice);
        uint256 dexOut = dex.swapBaseIn(orderSize / 4, 0, alice);

        assertGt(poolOut * 4 / 3, dexOut, "pool leg dominates");

        rollBlocks(20);
        DnmPool.QuoteResult memory calmQuote = quote(orderSize, true, IDnmPool.OracleMode.Spot);
        assertLt(calmQuote.feeBpsUsed, poolQuote.feeBpsUsed, "fee decays");
        assertGt(calmQuote.amountOut, dex.quoteBaseIn(orderSize), "still competitive");
    }

    function _sign(IQuoteRFQ.QuoteParams memory params) internal returns (bytes memory) {
        bytes32 typeHash = keccak256(
            "Quote(address taker,uint256 amountIn,uint256 minAmountOut,bool isBaseIn,uint256 expiry,uint256 salt,address pool,uint256 chainId)"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                typeHash,
                params.taker,
                params.amountIn,
                params.minAmountOut,
                params.isBaseIn,
                params.expiry,
                params.salt,
                address(pool),
                block.chainid
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
