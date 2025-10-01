// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {FixedPointMath} from "../../contracts/lib/FixedPointMath.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract ScenarioPreviewAomqTest is BaseTest {
    uint256 internal quoteScale;
    uint256 internal baseScale;

    function setUp() public {
        setUpBase();
        (, , , , baseScale, quoteScale) = pool.tokens();

        approveAll(alice);
        approveAll(bob);

        DnmPool.PreviewConfig memory previewCfg = DnmPool.PreviewConfig({
            maxAgeSec: 30,
            snapshotCooldownSec: 5,
            revertOnStalePreview: true,
            enablePreviewFresh: false
        });
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Preview, abi.encode(previewCfg));

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.enableAOMQ = true;
        flags.enableBboFloor = true;
        flags.enableSizeFee = true;
        setFeatureFlags(flags);

        DnmPool.AomqConfig memory aomqCfg = defaultAomqConfig();
        aomqCfg.minQuoteNotional = 40_000000;
        aomqCfg.emergencySpreadBps = 150;
        aomqCfg.floorEpsilonBps = 200;
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Aomq, abi.encode(aomqCfg));

        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();
        makerCfg.alphaBboBps = 5_000;
        makerCfg.betaFloorBps = 20;
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Maker, abi.encode(makerCfg));

        // Make the pool quote reserves scarce so AOMQ clamps large asks.
        usdc.transfer(address(pool), 500_000000);
        pool.sync();

        updateSpot(1e18, 5, true);
        updateBidAsk(999e15, 1_001e15, 200, true);
        updatePyth(1_015e18, 1e18, 0, 0, 5, 5);

        vm.warp(block.timestamp + 20);
        pool.refreshPreviewSnapshot(IDnmPool.OracleMode.Spot, bytes(""));
    }

    function test_previewLadderMatchesQuotesWithClampSignals() public {
        uint256[] memory sizes;
        uint256[] memory askFees;
        uint256[] memory bidFees;
        bool[] memory askClamped;
        bool[] memory bidClamped;
        uint64 snapshotTsLocal;
        uint96 snapshotMidLocal;
        (sizes, askFees, bidFees, askClamped, bidClamped, snapshotTsLocal, snapshotMidLocal) = pool.previewLadder(0);

        assertLe(snapshotTsLocal, uint64(block.timestamp), "snapshot timestamp future");
        assertGt(snapshotMidLocal, 0, "snapshot mid unset");

        bool sawClamp;
        for (uint256 i = 0; i < sizes.length; ++i) {
            if (askClamped[i] || bidClamped[i]) {
                sawClamp = true;
            }

            uint256 baseWad = sizes[i];
            uint256 baseAmount = FixedPointMath.mulDivDown(baseWad, baseScale, WAD);
            IDnmPool.QuoteResult memory askQuote =
                pool.quoteSwapExactIn(baseAmount, true, IDnmPool.OracleMode.Spot, bytes(""));
            assertEq(askQuote.feeBpsUsed, askFees[i], "ask fee parity");

            uint256 quoteNotionalWad = FixedPointMath.mulDivUp(baseWad, askQuote.midUsed, WAD);
            uint256 quoteAmount = FixedPointMath.mulDivUp(quoteNotionalWad, quoteScale, WAD);
            IDnmPool.QuoteResult memory bidQuote =
                pool.quoteSwapExactIn(quoteAmount, false, IDnmPool.OracleMode.Spot, bytes(""));
            assertEq(bidQuote.feeBpsUsed, bidFees[i], "bid fee parity");
        }

        assertTrue(sawClamp, "expected clamp from AOMQ");
    }
}
