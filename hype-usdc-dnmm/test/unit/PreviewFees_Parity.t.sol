// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";
import {FixedPointMath} from "../../contracts/lib/FixedPointMath.sol";
import {Inventory} from "../../contracts/lib/Inventory.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract PreviewFeesParityTest is BaseTest {
    uint256[] internal ladder;
    uint256 internal baseScale;
    uint256 internal quoteScale;

    function setUp() public {
        setUpBase();
        (,,,, uint256 baseScaleLocal, uint256 quoteScaleLocal) = pool.tokens();
        baseScale = baseScaleLocal;
        quoteScale = quoteScaleLocal;

        DnmPool.PreviewConfig memory previewCfg = DnmPool.PreviewConfig({
            maxAgeSec: 30,
            snapshotCooldownSec: 10,
            revertOnStalePreview: true,
            enablePreviewFresh: false
        });
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Preview, abi.encode(previewCfg));

        approveAll(alice);
        approveAll(bob);

        ladder = new uint256[](4);
        ladder[0] = 500_000_000_000_000_000; // 0.5 base
        ladder[1] = 1e18; // 1 base
        ladder[2] = 2e18; // 2 base
        ladder[3] = 5e18; // 5 base

        // Calibrate configs so each flag path is active when enabled.
        FeePolicy.FeeConfig memory feeCfg = defaultFeeConfig();
        feeCfg.gammaSizeLinBps = 50;
        feeCfg.gammaSizeQuadBps = 5;
        feeCfg.sizeFeeCapBps = 90;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Fee, abi.encode(feeCfg));

        DnmPool.InventoryConfig memory invCfg = defaultInventoryConfig();
        invCfg.invTiltBpsPer1pct = 200;
        invCfg.invTiltMaxBps = 250;
        invCfg.tiltConfWeightBps = 5000;
        invCfg.tiltSpreadWeightBps = 5000;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Inventory, abi.encode(invCfg));

        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();
        makerCfg.alphaBboBps = 5_000; // 50% of spread
        makerCfg.betaFloorBps = 15;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Maker, abi.encode(makerCfg));

        DnmPool.AomqConfig memory aomqCfg = defaultAomqConfig();
        aomqCfg.minQuoteNotional = 35_000000; // 35 quote units
        aomqCfg.emergencySpreadBps = 150;
        aomqCfg.floorEpsilonBps = 300;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Aomq, abi.encode(aomqCfg));

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.enableSizeFee = true;
        flags.enableInvTilt = true;
        flags.enableBboFloor = true;
        flags.enableAOMQ = true;
        flags.enableSoftDivergence = true;
        setFeatureFlags(flags);

        // Nudge oracle to create mild divergence but below hard threshold.
        updateSpot(1e18, 4, true);
        updateBidAsk(998_500_000_000_000_000, 1_001_500_000_000_000_000, 60, true);
        updatePyth(1_003_000_000_000_000_000, 1_000_000_000_000_000_000, 1, 1, 5, 5);

        // Make inventory slightly imbalanced so tilt + AOMQ have effect.
        vm.prank(alice);
        pool.swapExactIn(20_000 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        vm.prank(bob);
        pool.swapExactIn(1_000_000000, 0, false, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        // Trim quote reserves near the inventory floor to guarantee AOMQ clamps for large ladders.
        require(usdc.transfer(address(pool), 500_000000), "ERC20: transfer failed");
        pool.sync();
        (, uint128 quoteReserveBefore) = pool.reserves();
        uint256 targetQuoteReserves = 150_000000;
        if (quoteReserveBefore > targetQuoteReserves) {
            uint256 burnAmount = uint256(quoteReserveBefore) - targetQuoteReserves;
            vm.prank(address(pool));
            require(usdc.transfer(address(0xdead), burnAmount), "ERC20: transfer failed");
            pool.sync();
        }
        (, uint128 quoteReserve) = pool.reserves();
        uint16 floorBps;
        (, floorBps,,,,,) = pool.inventoryConfig();
        uint256 floorAmount = Inventory.floorAmount(uint256(quoteReserve), floorBps);
        uint256 availableQuote = uint256(quoteReserve) - floorAmount;
        uint256 s0QuoteUnits = FixedPointMath.mulDivDown(uint256(makerCfg.s0Notional), quoteScale, WAD);
        if (s0QuoteUnits == 0) {
            s0QuoteUnits = uint256(makerCfg.s0Notional);
        }
        uint256 epsilonWindow = FixedPointMath.mulDivDown(s0QuoteUnits, aomqCfg.floorEpsilonBps, BPS);
        if (epsilonWindow == 0) {
            epsilonWindow = 1;
        }
        assertLe(availableQuote, epsilonWindow, "near-floor slack");

        vm.warp(block.timestamp + 20);
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
        (uint32 maxAgeSec,,,) = pool.previewConfig();
        uint256 warpBy = uint256(maxAgeSec) + 1;
        vm.warp(block.timestamp + warpBy);
        vm.expectRevert(abi.encodeWithSelector(DnmPool.PreviewSnapshotStale.selector, warpBy, uint256(maxAgeSec)));
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
        returns (uint256[] memory askFees, uint256[] memory bidFees, bool[] memory askClamped, bool[] memory bidClamped)
    {
        uint64 snapshotTsLocal;
        uint96 snapshotMidLocal;
        (, askFees, bidFees, askClamped, bidClamped, snapshotTsLocal, snapshotMidLocal) = pool.previewLadder(0);

        assertLe(snapshotTsLocal, uint64(block.timestamp), "snapshot timestamp future");
        assertGt(snapshotMidLocal, 0, "snapshot mid unset");
    }
}
