// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {Errors} from "../../contracts/lib/Errors.sol";

contract ConfigSchemaTest is BaseTest {
    function setUp() public virtual {
        setUpBase();
    }

    function test_featureFlagsExposeAomqAndRebates() public view {
        DnmPool.FeatureFlags memory flags = getFeatureFlags();

        assertEq(flags.enableAOMQ, false, "AOMQ default");
        assertEq(flags.enableRebates, false, "Rebates default");
        assertEq(flags.enableAutoRecenter, false, "Auto recenter default");
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

    function test_governanceConfigExposesTimelockDelay() public view {
        DnmPool.GovernanceConfig memory cfg = pool.governanceConfig();

        assertEq(cfg.timelockDelaySec, 0, "timelock default");
    }

    function test_previewConfigDefaults() public view {
        (uint32 maxAgeSec, uint32 cooldownSec, bool revertOnStale, bool enableFresh) = pool.previewConfig();

        assertEq(maxAgeSec, 0, "preview max age disabled by default");
        assertEq(cooldownSec, 0, "preview cooldown default");
        assertFalse(revertOnStale, "preview revert default");
        assertFalse(enableFresh, "preview fresh disabled");
    }

    function test_rebateDefaultsAreZero() public view {
        assertEq(pool.aggregatorDiscount(alice), 0, "alice discount default");
        assertEq(pool.aggregatorDiscount(bob), 0, "bob discount default");
    }

    function test_updateInventoryRejectsTiltBounds() public {
        DnmPool.InventoryConfig memory cfg = defaultInventoryConfig();
        cfg.invTiltMaxBps = 10_001;

        vm.prank(gov);
        vm.expectRevert(Errors.InvalidConfig.selector);
        pool.updateParams(IDnmPool.ParamKind.Inventory, abi.encode(cfg));
    }

    function test_updateMakerRejectsAlphaAboveOne() public {
        DnmPool.MakerConfig memory cfg = defaultMakerConfig();
        cfg.alphaBboBps = 10_001;

        vm.prank(gov);
        vm.expectRevert(Errors.InvalidConfig.selector);
        pool.updateParams(IDnmPool.ParamKind.Maker, abi.encode(cfg));
    }

    function test_updateAomqRejectsSpreadAboveOne() public {
        DnmPool.AomqConfig memory cfg = defaultAomqConfig();
        cfg.emergencySpreadBps = 10_001;

        vm.prank(gov);
        vm.expectRevert(Errors.InvalidConfig.selector);
        pool.updateParams(IDnmPool.ParamKind.Aomq, abi.encode(cfg));
    }
}
