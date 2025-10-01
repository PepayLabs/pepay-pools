// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract BboFloorTest is BaseTest {
    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);
    }

    function test_floorTracksOrderbookSpread() public {
        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.enableBboFloor = true;
        setFeatureFlags(flags);

        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();
        makerCfg.alphaBboBps = 5_000; // 50% of spread
        makerCfg.betaFloorBps = 10; // fallback absolute floor
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Maker, abi.encode(makerCfg));

        updateSpot(1e18, 1, true);
        updateBidAsk(995e15, 1_005e15, 200, true); // 200 bps spread
        updateEma(1e18, 1, true);

        // Baseline with the flag disabled should stay near the base fee (15 bps)
        flags.enableBboFloor = false;
        setFeatureFlags(flags);
        DnmPool.QuoteResult memory baseline =
            pool.quoteSwapExactIn(1_000 ether, true, IDnmPool.OracleMode.Spot, bytes(""));
        assertLt(baseline.feeBpsUsed, 100, "baseline should stay below floor target");

        // Toggle floor and ensure we clamp to alpha x spread (100 bps)
        flags.enableBboFloor = true;
        setFeatureFlags(flags);
        DnmPool.QuoteResult memory floored =
            pool.quoteSwapExactIn(1_000 ether, true, IDnmPool.OracleMode.Spot, bytes(""));
        assertEq(floored.feeBpsUsed, 100, "alpha percent spread floor");
    }

    function test_floorFallsBackToAbsoluteWhenSpreadMissing() public {
        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.enableBboFloor = true;
        setFeatureFlags(flags);

        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();
        makerCfg.alphaBboBps = 8_000; // 80%
        makerCfg.betaFloorBps = 25; // safety absolute floor
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Maker, abi.encode(makerCfg));

        updateSpot(1e18, 1, true);
        updateBidAsk(0, 0, 0, false); // spread unavailable
        updateEma(1e18, 1, true);

        DnmPool.QuoteResult memory result =
            pool.quoteSwapExactIn(500 ether, true, IDnmPool.OracleMode.Spot, bytes(""));
        assertEq(result.feeBpsUsed, 25, "fallback absolute floor when spread missing");
    }

    function test_floorRespectsCap() public {
        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.enableBboFloor = true;
        setFeatureFlags(flags);

        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();
        makerCfg.alphaBboBps = 10_000; // 100%
        makerCfg.betaFloorBps = 10;
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Maker, abi.encode(makerCfg));

        updateSpot(1e18, 1, true);
        updateBidAsk(900e15, 1_100e15, 2_000, true); // 2000 bps spread would push above cap
        updateEma(1e18, 1, true);

        DnmPool.QuoteResult memory result =
            pool.quoteSwapExactIn(800 ether, true, IDnmPool.OracleMode.Spot, bytes(""));
        assertEq(result.feeBpsUsed, 150, "clamped by fee cap");
    }
}
