// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {FixedPointMath} from "../../contracts/lib/FixedPointMath.sol";
import {Inventory} from "../../contracts/lib/Inventory.sol";
import {IOracleAdapterPyth} from "../../contracts/interfaces/IOracleAdapterPyth.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract ScenarioPreviewAomqTest is BaseTest {
    uint256 internal quoteScale;
    uint256 internal baseScale;

    function setUp() public {
        setUpBase();
        (,,,, baseScale, quoteScale) = pool.tokens();

        approveAll(alice);
        approveAll(bob);

        DnmPool.PreviewConfig memory previewCfg = DnmPool.PreviewConfig({
            maxAgeSec: 30,
            snapshotCooldownSec: 5,
            revertOnStalePreview: true,
            enablePreviewFresh: false
        });
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Preview, abi.encode(previewCfg));

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.enableAOMQ = true;
        flags.enableBboFloor = true;
        flags.enableSizeFee = true;
        setFeatureFlags(flags);

        DnmPool.OracleConfig memory oracleCfg = defaultOracleConfig();
        oracleCfg.divergenceBps = 150;
        oracleCfg.divergenceSoftBps = 150;
        oracleCfg.divergenceHardBps = 200;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Oracle, abi.encode(oracleCfg));

        DnmPool.AomqConfig memory aomqCfg = defaultAomqConfig();
        aomqCfg.minQuoteNotional = 35_000000;
        aomqCfg.emergencySpreadBps = 150;
        aomqCfg.floorEpsilonBps = 300;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Aomq, abi.encode(aomqCfg));

        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();
        makerCfg.s0Notional = 10_000 ether;
        makerCfg.alphaBboBps = 5_000;
        makerCfg.betaFloorBps = 20;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Maker, abi.encode(makerCfg));

        // Make the pool quote reserves scarce so AOMQ clamps large asks.
        require(usdc.transfer(address(pool), 500_000000), "ERC20: transfer failed");
        pool.sync();
        (, uint128 quoteReserveBefore) = pool.reserves();
        uint256 targetQuoteReserves = 300_000000; // ~300 quote units (6 decimals)
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

        updateSpot(1e18, 5, true);
        updateBidAsk(999e15, 1_001e15, 200, true);
        updatePyth(1015e15, 1e18, 0, 0, 5, 5);
        IOracleAdapterPyth.PythResult memory latest = oraclePyth.peekPythUsdMid();
        (uint256 pairMid,,) = oraclePyth.computePairMid(latest);
        assertApproxEqAbs(pairMid, 1015e15, 1, "pyth mid configured");

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
