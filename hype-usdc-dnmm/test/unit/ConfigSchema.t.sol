// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {Errors} from "../../contracts/lib/Errors.sol";

contract ConfigSchemaTest is BaseTest {
    function setUp() public virtual {
        setUpBase();
    }

    function test_inventoryConfigExposesTiltFields() public view {
        (
            uint128 target,
            uint16 floorBps,
            uint16 recenterThresholdPct,
            uint16 tiltBpsPer1pct,
            uint16 tiltMaxBps,
            uint16 tiltConfWeightBps,
            uint16 tiltSpreadWeightBps
        ) = pool.inventoryConfig();

        assertEq(target, 100_000 ether, "target default");
        assertEq(floorBps, 300, "floor default");
        assertEq(recenterThresholdPct, 750, "threshold default");
        assertEq(tiltBpsPer1pct, 0, "tilt slope default");
        assertEq(tiltMaxBps, 0, "tilt cap default");
        assertEq(tiltConfWeightBps, 0, "tilt conf weight default");
        assertEq(tiltSpreadWeightBps, 0, "tilt spread weight default");
    }

    function test_makerConfigExposesBboFloorFields() public view {
        (
            uint128 s0Notional,
            uint32 ttlMs,
            uint16 alphaBboBps,
            uint16 betaFloorBps
        ) = pool.makerConfig();

        assertEq(s0Notional, 5_000 ether, "S0 default");
        assertEq(ttlMs, 300, "TTL default");
        assertEq(alphaBboBps, 0, "alpha default");
        assertEq(betaFloorBps, 0, "beta default");
    }

    function test_aomqConfigExposesEmergencyFields() public view {
        (uint128 minQuoteNotional, uint16 emergencySpreadBps, uint16 floorEpsilonBps) = pool.aomqConfig();

        assertEq(minQuoteNotional, 0, "min quote default");
        assertEq(emergencySpreadBps, 0, "emergency spread default");
        assertEq(floorEpsilonBps, 0, "floor epsilon default");
    }

    function test_updateInventoryRejectsTiltBounds() public {
        DnmPool.InventoryConfig memory cfg = defaultInventoryConfig();
        cfg.invTiltMaxBps = 10_001;

        vm.prank(gov);
        vm.expectRevert(Errors.InvalidConfig.selector);
        pool.updateParams(DnmPool.ParamKind.Inventory, abi.encode(cfg));
    }

    function test_updateMakerRejectsAlphaAboveOne() public {
        DnmPool.MakerConfig memory cfg = defaultMakerConfig();
        cfg.alphaBboBps = 10_001;

        vm.prank(gov);
        vm.expectRevert(Errors.InvalidConfig.selector);
        pool.updateParams(DnmPool.ParamKind.Maker, abi.encode(cfg));
    }

    function test_updateAomqRejectsSpreadAboveOne() public {
        DnmPool.AomqConfig memory cfg = defaultAomqConfig();
        cfg.emergencySpreadBps = 10_001;

        vm.prank(gov);
        vm.expectRevert(Errors.InvalidConfig.selector);
        pool.updateParams(DnmPool.ParamKind.Aomq, abi.encode(cfg));
    }
}
