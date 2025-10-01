// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";
import {FixedPointMath} from "../../contracts/lib/FixedPointMath.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract PreviewFeesParityTest is BaseTest {
    uint256[] internal ladder;
    uint256 internal baseScale;
    uint256 internal quoteScale;

    function setUp() public {
        setUpBase();
        (, , , , uint256 baseScaleLocal, uint256 quoteScaleLocal) = pool.tokens();
        baseScale = baseScaleLocal;
        quoteScale = quoteScaleLocal;

        ladder = new uint256[](4);
        ladder[0] = 5e17; // 0.5 base
        ladder[1] = 1e18; // 1 base
        ladder[2] = 2e18; // 2 base
        ladder[3] = 5e18; // 5 base

        // Calibrate configs so each flag path is active when enabled.
        FeePolicy.FeeConfig memory feeCfg = defaultFeeConfig();
        feeCfg.gammaSizeLinBps = 50;
        feeCfg.gammaSizeQuadBps = 5;
        feeCfg.sizeFeeCapBps = 90;
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Fee, abi.encode(feeCfg));

        DnmPool.InventoryConfig memory invCfg = defaultInventoryConfig();
        invCfg.invTiltBpsPer1pct = 200;
        invCfg.invTiltMaxBps = 250;
        invCfg.tiltConfWeightBps = 5000;
        invCfg.tiltSpreadWeightBps = 5000;
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Inventory, abi.encode(invCfg));

        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();
        makerCfg.alphaBboBps = 5_000; // 50% of spread
        makerCfg.betaFloorBps = 15;
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Maker, abi.encode(makerCfg));

        DnmPool.AomqConfig memory aomqCfg = defaultAomqConfig();
        aomqCfg.minQuoteNotional = 50_000000; // 50 quote units
        aomqCfg.emergencySpreadBps = 120;
        aomqCfg.floorEpsilonBps = 200;
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Aomq, abi.encode(aomqCfg));

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.enableSizeFee = true;
        flags.enableInvTilt = true;
        flags.enableBboFloor = true;
        flags.enableAOMQ = true;
        flags.enableSoftDivergence = true;
        setFeatureFlags(flags);

        // Nudge oracle to create mild divergence but below hard threshold.
        updateSpot(1e18, 4, true);
        updateBidAsk(999e15, 1_001e15, 200, true);
        updatePyth(1_012e18, 1e18, 1, 1, 5, 5);

        // Make inventory slightly imbalanced so tilt + AOMQ have effect.
        vm.prank(alice);
        pool.swapExactIn(20_000 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        vm.prank(bob);
        pool.swapExactIn(1_000_000000, 0, false, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        // Capture a fresh snapshot.
        pool.refreshPreviewSnapshot(IDnmPool.OracleMode.Spot, bytes(""));
    }

    function test_previewFeesMatchesQuotes() public {
        (uint256[] memory askFees, uint256[] memory bidFees) = pool.previewFees(ladder);

        for (uint256 i = 0; i < ladder.length; ++i) {
            uint256 baseSizeWad = ladder[i];
            if (baseSizeWad == 0) continue;

        uint256 baseAmount = FixedPointMath.mulDivDown(baseSizeWad, baseScale, WAD);
            IDnmPool.QuoteResult memory askQuote =
                pool.quoteSwapExactIn(baseAmount, true, IDnmPool.OracleMode.Spot, bytes(""));
            assertEq(askQuote.feeBpsUsed, askFees[i], string(abi.encodePacked("ask fee mismatch ", vm.toString(i))));

            uint256 quoteNotionalWad = FixedPointMath.mulDivUp(baseSizeWad, askQuote.midUsed, WAD);
            uint256 quoteAmount = FixedPointMath.mulDivUp(quoteNotionalWad, quoteScale, WAD);
            IDnmPool.QuoteResult memory bidQuote =
                pool.quoteSwapExactIn(quoteAmount, false, IDnmPool.OracleMode.Spot, bytes(""));
            assertEq(bidQuote.feeBpsUsed, bidFees[i], string(abi.encodePacked("bid fee mismatch ", vm.toString(i))));
        }
    }

    function test_previewFeesStalenessRevertsWhenConfigured() public {
        vm.warp(block.timestamp + 31);
        vm.expectRevert(DnmPool.PreviewSnapshotStale.selector);
        pool.previewFees(ladder);
    }

    function test_previewFeesClampFlags() public {
        (,, bool[] memory askClamped, bool[] memory bidClamped) = _previewFeesWithFlags();
        bool sawClamp;
        for (uint256 i = 0; i < askClamped.length; ++i) {
            if (askClamped[i] || bidClamped[i]) {
                sawClamp = true;
            }
        }
        assertTrue(sawClamp, "expect AOMQ clamp on large sizes");
    }

    function _previewFeesWithFlags()
        internal
        view
        returns (
            uint256[] memory askFees,
            uint256[] memory bidFees,
            bool[] memory askClamped,
            bool[] memory bidClamped
        )
    {
        uint64 snapshotTsLocal;
        uint96 snapshotMidLocal;
        uint256[] memory sizes;
        uint256[] memory askFeesLocal;
        uint256[] memory bidFeesLocal;
        bool[] memory askClampedLocal;
        bool[] memory bidClampedLocal;
        (sizes, askFeesLocal, bidFeesLocal, askClampedLocal, bidClampedLocal, snapshotTsLocal, snapshotMidLocal) =
            pool.previewLadder(0);
        sizes;
        snapshotTsLocal;
        snapshotMidLocal;
        askFees = askFeesLocal;
        bidFees = bidFeesLocal;
        askClamped = askClampedLocal;
        bidClamped = bidClampedLocal;
    }
}
