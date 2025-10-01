// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {FixedPointMath} from "../../contracts/lib/FixedPointMath.sol";

contract InventoryTiltTest is BaseTest {
    uint256 internal constant ONE = 1e18;

    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);
        updateSpot(1e18, 1, true);
        updateBidAsk(999e15, 1_001e15, 200, true);
        updateEma(1e18, 1, true);
    }

    function test_invTiltPenalisesTradesThatWorsenDeviation() public {
        // Make the pool base-heavy by depositing additional base and syncing reserves.
        hype.transfer(address(pool), 50_000 ether);
        pool.sync();

        // Configure tilt parameters and enable the feature flag.
        DnmPool.InventoryConfig memory invCfg = defaultInventoryConfig();
        invCfg.invTiltBpsPer1pct = 25; // 0.25 bps per 1 bps deviation
        invCfg.invTiltMaxBps = 20; // clamp at 20 bps
        invCfg.tiltConfWeightBps = 0;
        invCfg.tiltSpreadWeightBps = 0;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Inventory, abi.encode(invCfg));

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.enableInvTilt = false;
        setFeatureFlags(flags);

        // Baseline fees with tilt disabled.
        DnmPool.QuoteResult memory baseInBaseline =
            pool.quoteSwapExactIn(5_000 ether, true, IDnmPool.OracleMode.Spot, bytes(""));
        DnmPool.QuoteResult memory quoteInBaseline =
            pool.quoteSwapExactIn(2_000_000000, false, IDnmPool.OracleMode.Spot, bytes(""));

        // Enable inventory tilt.
        flags.enableInvTilt = true;
        setFeatureFlags(flags);

        DnmPool.QuoteResult memory baseInTilted =
            pool.quoteSwapExactIn(5_000 ether, true, IDnmPool.OracleMode.Spot, bytes(""));
        DnmPool.QuoteResult memory quoteInTilted =
            pool.quoteSwapExactIn(2_000_000000, false, IDnmPool.OracleMode.Spot, bytes(""));

        // Base-heavy pool should increase fees for base-in trades (worsens deviation)
        // and decrease fees for quote-in trades (restores balance).
        assertGte(baseInTilted.feeBpsUsed, baseInBaseline.feeBpsUsed, "base-in fee should not decrease");
        assertLt(quoteInTilted.feeBpsUsed, quoteInBaseline.feeBpsUsed, "quote-in fee should decrease");
    }

    function test_invTiltMatchesWeightedComputation() public {
        // Leave pool base-light (default state) but configure explicit tilt values.
        DnmPool.InventoryConfig memory invCfg = defaultInventoryConfig();
        invCfg.invTiltBpsPer1pct = 40; // 0.4 bps per 1 bps deviation
        invCfg.invTiltMaxBps = 80;
        invCfg.tiltConfWeightBps = 0;
        invCfg.tiltSpreadWeightBps = 10_000; // weight spread 1:1
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Inventory, abi.encode(invCfg));

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.enableInvTilt = false;
        setFeatureFlags(flags);

        // Baseline quote (tilt disabled) for a quote-in trade.
        DnmPool.QuoteResult memory baseline =
            pool.quoteSwapExactIn(1_000_000000, false, IDnmPool.OracleMode.Spot, bytes(""));

        // Enable tilt and recompute.
        flags.enableInvTilt = true;
        setFeatureFlags(flags);

        DnmPool.QuoteResult memory tilted =
            pool.quoteSwapExactIn(1_000_000000, false, IDnmPool.OracleMode.Spot, bytes(""));

        (uint256 expectedTilt, bool increaseFee) = _expectedTilt(false);
        uint256 expectedFee = increaseFee
            ? baseline.feeBpsUsed + expectedTilt
            : (baseline.feeBpsUsed > expectedTilt ? baseline.feeBpsUsed - expectedTilt : 0);
        assertEq(tilted.feeBpsUsed, expectedFee, "tilt should match weighted computation");
    }

    function _expectedTilt(bool isBaseIn) internal view returns (uint256 tiltBps, bool increaseFee) {
        (uint128 baseRes, uint128 quoteRes) = pool.reserves();

        uint256 baseWad = FixedPointMath.mulDivDown(uint256(baseRes), ONE, 1e18);
        uint256 quoteWad = FixedPointMath.mulDivDown(uint256(quoteRes), ONE, 1e6);
        uint256 mid = 1e18;

        uint256 numerator = quoteWad + FixedPointMath.mulDivDown(baseWad, mid, ONE);
        uint256 xStar = FixedPointMath.mulDivDown(numerator, ONE, mid * 2);

        uint256 delta;
        bool baseHeavy;
        if (baseWad >= xStar) {
            baseHeavy = true;
            delta = baseWad - xStar;
        } else {
            baseHeavy = false;
            delta = xStar - baseWad;
        }

        if (delta == 0 || xStar == 0) return (0, false);

        uint256 deltaBps = FixedPointMath.toBps(delta, xStar);
        if (deltaBps == 0) return (0, false);

        uint16 invTiltBpsPer1pct;
        uint16 invTiltMaxBps;
        uint16 tiltSpreadWeightBps;
        (, , , invTiltBpsPer1pct, invTiltMaxBps, , tiltSpreadWeightBps) = pool.inventoryConfig();

        uint256 tiltBase = FixedPointMath.mulDivDown(deltaBps, invTiltBpsPer1pct, 100);

        uint256 weightFactor = BPS;
        uint256 spreadBps = 200; // from setUp()
        weightFactor += FixedPointMath.mulDivDown(spreadBps, tiltSpreadWeightBps, BPS);

        uint256 weightedTilt = FixedPointMath.mulDivDown(tiltBase, weightFactor, BPS);
        if (weightedTilt > invTiltMaxBps) weightedTilt = invTiltMaxBps;
        if (weightedTilt == 0) return (0, false);

        bool increase = isBaseIn ? baseHeavy : !baseHeavy;
        return (weightedTilt, increase);
    }
}
